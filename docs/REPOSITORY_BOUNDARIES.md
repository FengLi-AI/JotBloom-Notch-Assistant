# 仓库边界与协作

本仓库包含完整、免费、MIT 开源的萌生客户端。只克隆本仓库即可构建，不依赖私有仓库、登录或激活服务。

| 内容 | 位置 |
| --- | --- |
| 灵感、剪贴板、提示词、AI 对话、搜索与设置 | JotBloom / JotBloomCore |
| 六个像素小伙伴、刘海拖入、本机 Codex 完成提醒 | JotBloom/Companion |
| 原创角色、动作和生命周期 | JotBloom/Resources/Companions |
| 官网和网页体验 | site / site/companions |

角色的身体、眼睛、耳朵、尾巴或翅膀分开绘制，动作采用本地连续插值。网页与原生应用使用相同的动画资源，运行 `python3 scripts/sync-companion-web.py` 同步；提交前用 `--check` 验证一致。

网页中的桌面、刘海和面板为原创交互演示，不包含外部壁纸、Figma 文件或用户数据。网页不连接 Codex；演示拖入只在页面内暂存，刷新即清空。

未来另行开发的商业 Agent、授权与支付服务不属于当前公开客户端。不得导入这些未授权公开的实现、私有开发历史、凭据、运行数据或内部设计参考。

## 检查

```sh
python3 scripts/check-repository-boundary.py
python3 scripts/sync-companion-web.py --check
node --test scripts/check-native-art.cjs
bash scripts/check-codex-events.sh
```

公开边界检查与推送钩子继续拦截已知私有目录、内部预览、凭据和用户数据；原创小伙伴动画资源属于明确允许公开的内容。发布前审查提交差异与安装包，不能仅依赖文件名检查。
