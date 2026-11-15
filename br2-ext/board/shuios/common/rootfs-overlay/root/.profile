# /root/.profile — 文本控制台（tty2 起）自动进入 shui
#
# tty1 归桌面（Weston/DRM）独占，所以文本会话放到 tty2+。
# 桌面里的终端跑同一个 shui，两种入口体验一致。
if [ -t 0 ] && [ -x /usr/bin/shui ]; then
    case "$(tty 2>/dev/null)" in
        /dev/tty2|/dev/tty3|/dev/tty4)
            exec /usr/bin/shui
            ;;
    esac
fi
