本期主攻 agent 功能，全程桌面仓只改文档不动代码，主改动在插件仓。

准备构建记忆模型（目前的记忆功能简陋，就是一个 md 文件由 agent 随意写）

## 1. 目标
记忆 手动+自动管理、手动查询+按需自动推送、分级存储

## 2. 记忆模型：
```
uuid str
level str(mandatory-requirement/preferences/conditional)
title  str
keywords  List[str]
recall_conditions  List[str]
content  str(background+)
```
## 3. 实施草案

1. 前置：内置工具增加 MemoryManager，提供 agent 手动记忆管理的途径。
2. 手动管理工具 MemoryManager 的方法：
- in：写入记忆（每次一条，可指定 id 用于覆盖，确省自动生成 24 位 id，指定时仅需前 6 位，偶然同时命中多个要求增加位数重试）
- recall：查询记忆（向量查询，无向量模型回退为grep 关键词，可指定条数）

注：要求 in 前必须先 recall 查询是否已有相关存量记忆，
