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

    def cancel_agent(self, user_id: str, agent_id: str) -> int:
        """停止指定 agent 的 worker：取消在途任务并清空其消息队列。

        用于「停止」按钮级联（TOP agent + 其下全部成员）。仅置位取消事件
        不足以让成员停下来：worker 处理完当前消息后会继续消费队列里残留的
        消息，把已停止的成员又拉起来工作。此处：

        1. 清空该 agent 的消息队列（排队的消息全部丢弃，不再被处理）；
        2. 取消其 worker future（若在途），使 ``_run`` 收到 CancelledError
           退出；正在执行的消息处理协程的 ``finally`` 会照常复位状态、
           推送 idle（取消事件驱动其 chat 线程在下一个检查点退出，不会硬杀）。

        注意：若该 agent 当前正阻塞在同步工具调用（如长 terminal 命令）中，
        取消无法强行中断该工具线程，工具返回后 chat 线程在检查点退出。

        :return: 被清空的排队消息数
        """
        key = (user_id, agent_id)
        cleared = 0
        queue = self._queues.get(key)
        if queue is not None:
            with queue.mutex:
                cleared = len(queue.queue)
                queue.queue.clear()
        worker = self._workers.get(key)
        if worker is not None and not worker.done():
            worker.cancel()
        return cleared

    def remove_agent(self, user_id: str, agent_id: str) -> int:
        """彻底移除 agent 的队列与 worker 注册（agent 删除时调用）。

        与 ``cancel_agent``（停止但保留注册，可继续接收消息）不同：
        ``remove_agent`` 在取消在途 worker 后删除 ``_queues`` / ``_workers``
        条目，避免 300+ agent 7×24 长跑下注册表无限增长（内存泄漏）。

        :return: 被清空的排队消息数
        """
        key = (user_id, agent_id)
        cleared = 0
        queue = self._queues.pop(key, None)
        if queue is not None:
            with queue.mutex:
                cleared = len(queue.queue)
                queue.queue.clear()
        worker = self._workers.pop(key, None)
        if worker is not None and not worker.done():
            worker.cancel()
        return cleared

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

    @staticmethod
    async def _wait_payload(queue: _queue.Queue) -> dict:
        """轻量轮询取队列，不长期占用默认线程池线程。

        此前使用 ``asyncio.to_thread(queue.get)``：每个空闲 worker 会永久
        占用默认 ThreadPoolExecutor 的一个线程（get 阻塞直到有消息），
        agent 数量一多就把线程池占满，导致其他 to_thread 请求（REST 读、
        本地 WS 读写等）全部排队阻塞，表现为"一个请求卡住，其他请求全卡"。
        改为轮询 get_nowait + asyncio.sleep：空闲 worker 不占线程，
        消息投递延迟仅为一个轮询周期（50ms）。
        """
        while True:
            try:
                return queue.get_nowait()
            except _queue.Empty:
                await asyncio.sleep(0.05)

    async def _run(self, key: tuple, queue: _queue.Queue) -> None:
        """成员 worker：串行消费队列中的消息。

        将 ``queue`` 一并传给处理函数，使其能在当前消息的 tool_call
        间隙通过 ``on_tool_turn`` 回调切入处理新消息（chat 消费线程内
        调用 ``get_nowait``，queue.Queue 线程安全）。
        """
        while True:
            payload = await self._wait_payload(queue)
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