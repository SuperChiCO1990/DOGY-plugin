# 抖记DOGY Plugin

面向 Windows 的本机 Agent 插件。通过同一份 DOGY EXE 调用解析和下载工具。
本仓库只包含连接层，DOGY 核心源码不在此仓库中。源码未以开源许可证发布。

## 安装

仓库和正式 Release 发布完成后，用户可将 INSTALL.txt 全文发给 Codex。
插件通过 Codex 官方插件市场命令安装，不向公网开放 MCP 服务。
插件安装后由 Agent 运行 scripts/setup.ps1，优先使用本机 DOGY；未找到时下载发布 EXE。
重新开任务后检查 dogy_doctor。其他 Agent 需使用其支持的 MCP/Skill 配置方式。

本机程序记录与启动器保存到 `%LOCALAPPDATA%\MediaDownloader\Agent`；自动下载的
EXE 保存到 `%LOCALAPPDATA%\MediaDownloader\DOGY`。桌面不会增加配置文件夹。
插件更新与 DOGY 更新是两件事；本版本不包含软件内更新提示。

## 发布范围

仅发布此仓库目录里的文件。不要从原 DOGY 项目执行 git add -A 或整体上传。
正式 Release 附件需要 DOGY.exe、dogy-release.json 以及第三方许可说明。
下载来源：`SuperChiCO1990/DOGY-plugin` 的最新正式 Release。v1.13.0 已发布为正式版本，支持软件内更新检查。
