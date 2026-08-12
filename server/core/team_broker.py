"""团队成员消息投递器。

leader 通过 ``team send_message`` / ``assign_task`` 给成员投递消息时，
本模块负责把消息异步投递到对应成员的消息队列，并由每个成员独立的
后台 worker 串行消费处理。

设计要点：
- 每个成员（以 ``(user_id, agent_id)`` 标识）拥有独立的队列与 worker
- worker 串行处理队列中的消息，天然避免并发打断正在执行的 tool_call 或 LLM 生成
- ``dispatch`` 为同步方法（供 team 工具 handler 调用），通过 ``create_task``
  投递，不阻塞 leader 的 LLM 生成
"""

import asyncio
import concurrent.futures
import logging
import queue as _queue
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger(__name__)

# 处理函数签名：async fn(payload: dict, queue) -> None
ProcessFn = Callable[[dict, Any], Any]


class TeamMessageBroker:
    """成员消息投递与串行执行。"""

    def __init__(self, process_fn: ProcessFn) -> None:
        self._process_fn = process_fn
        # key -> queue.Queue（线程安全）。chat 消费线程会从该队列 peek 新消息，
        # 因此使用标准库 queue 而非 asyncio.Queue，避免跨线程访问的竞态。
        self._queues: Dict[tuple, _queue.Queue] = {}
        # key -> concurrent.futures.Future（worker 已在主事件循环上创建）
        self._workers: Dict[tuple, Any] = {}
        # 主事件循环：在构造（lifespan 协程上下文）时捕获，供 dispatch 从
        # 任意工作线程安全地调度 worker 任务。
        try:
            self._loop: Optional[Any] = asyncio.get_running_loop()
        except RuntimeError:
            self._loop = None

    def dispatch(self, key: tuple, payload: dict) -> bool:
        """同步投递一条消息给成员。

        :param key: ``(user_id, agent_id)`` 成员唯一标识
        :param payload: 消息负载（含 workspace_id / model_id / content 等）
        :return: 是否已入队
        """
        if not self._process_fn:
            return False
        queue = self._queues.setdefault(key, _queue.Queue())
        queue.put_nowait(payload)
        worker = self._workers.get(key)
        if worker is None or worker.done():
            if self._loop is None or self._loop.is_closed():
                logger.error("无可用事件循环，无法为成员 %s 启动 worker", key)
                return False
            # dispatch 可能在 chat 消费线程（无 running loop）中被调用，
            # 因此通过 run_coroutine_threadsafe 把 worker 调度到主事件循环。
            future = asyncio.run_coroutine_threadsafe(
                self._run(key, queue), self._loop
            )
            self._workers[key] = future
            # 吞掉 worker 异常并记录日志，避免 future 未被消费导致静默丢失。
            future.add_done_callback(self._on_worker_done)
        return True

    def _on_worker_done(self, future: Any) -> None:
        """worker 结束回调：记录未捕获的异常（不抛出到调度线程）。"""
        try:
            future.result()
        except (
            asyncio.CancelledError,
            concurrent.futures.CancelledError,
            KeyboardInterrupt,
        ):
            pass
        except Exception:  # noqa: BLE001
            logger.exception("成员 worker 异常结束")

    async def _run(self, key: tuple, queue: _queue.Queue) -> None:
        """成员 worker：串行消费队列中的消息。

        将 ``queue`` 一并传给处理函数，使其能在当前消息的 tool_call
        间隙通过 ``on_tool_turn`` 回调切入处理新消息（chat 消费线程内
        调用 ``get_nowait``，queue.Queue 线程安全）。
        """
        while True:
            # 在事件循环线程中阻塞等待队列；用 run_in_executor 避免阻塞循环。
            payload = await asyncio.to_thread(queue.get)
            try:
                result = self._process_fn(payload, queue)
                if asyncio.iscoroutine(result):
                    await result
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                logger.exception("成员消息处理异常, key=%s: %s", key, exc)
            finally:
                queue.task_done()