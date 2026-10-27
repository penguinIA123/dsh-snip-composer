// dsh-snip-composer — browser (client) half.
// Injects a "📷 截图提问" button into the conversation composer's left tool row.
// Clicking it opens a small dropdown menu:
//   - 框选截图     -> mode=region, drag-select a region
//   - 隐藏 DSH 后框选 -> mode=hide-region, hide DSH window first
//   - 全屏截图     -> mode=fullscreen, capture the whole virtual screen
// Each option POSTs to /_dsh/snip-composer/capture, which runs the PowerShell
// capture, copies the image to the clipboard, focuses DSH and pastes it into
// the composer (leaves it there — the user types their question and sends).
//
// Hand-written (no bundler): the DSH client module system wraps this in a CJS
// factory and the kernel adopts { name, apply, inject } as a client plugin.
// Only `require('react')` is used (createElement, no JSX runtime).

window.__ModuleLoader__.load({
  id: 'dsh-snip-composer',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    var React = require('react')
    var h = React.createElement
    var useEffect = React.useEffect
    var useRef = React.useRef
    var useState = React.useState

    var name = 'snip-composer'
    var SNIP_ROUTE = '/_dsh/snip-composer/capture'

    var MENU_ITEMS = [
      { key: 'region', label: '📷 框选截图' },
      { key: 'hide-region', label: '🙈 隐藏 DSH 后框选' },
      { key: 'fullscreen', label: '🖥️ 全屏截图' },
    ]

    function SnipButton() {
      var busyRef = useRef(false)
      var state = useState(null)
      var hint = state[0]
      var setHint = state[1]
      var openState = useState(false)
      var open = openState[0]
      var setOpen = openState[1]
      var rootRef = useRef(null)

      // 点击菜单外关闭下拉
      useEffect(function () {
        if (!open) return
        function onDocClick(e) {
          if (rootRef.current && !rootRef.current.contains(e.target)) {
            setOpen(false)
          }
        }
        document.addEventListener('mousedown', onDocClick)
        return function () { document.removeEventListener('mousedown', onDocClick) }
      }, [open])

      // 把 base64 PNG 派发成 paste 事件，走 DSH 聊天输入框（Lexical 编辑器）自己
      // 的 paste 通道插入图片。关键修复（bug1）：不再依赖全局焦点态，每次都可靠。
      //
      // 两个必须的坑：
      // 1) 聊天输入框是 Lexical 编辑器，它的原生 paste 监听器挂在根元素
      //    [data-lexical-editor="true"] 上（不在 document），所以事件必须派发到
      //    该元素（或其子节点 + bubbles），派发到 document 到达不了监听器。
      // 2) ClipboardEvent 构造函数不接受 clipboardData 参数（会被忽略），
      //    e.clipboardData 会是 null；必须用 Object.defineProperty 把 dt 钉到事件实例。
      function dispatchPasteFromBase64(imageB64) {
        try {
          var byteChars = atob(imageB64)
          var bytes = new Uint8Array(byteChars.length)
          for (var i = 0; i < byteChars.length; i++) bytes[i] = byteChars.charCodeAt(i)
          var file = new File([bytes], 'snip.png', { type: 'image/png' })
          var dt = new DataTransfer()
          dt.items.add(file)

          var ev = new ClipboardEvent('paste', { bubbles: true, cancelable: true })
          Object.defineProperty(ev, 'clipboardData', {
            value: dt,
            enumerable: true,
            configurable: true,
          })

          // 优先瞄准当前聚焦的输入框所在的 Lexical 根；找不到再退而求其次用首个
          // [data-lexical-editor="true"]，保证事件能命中元素级原生 paste 监听器。
          var active = document.activeElement
          var target =
            (active && active.closest
              ? active.closest('[data-lexical-editor="true"]')
              : null) ||
            document.querySelector('[data-lexical-editor="true"]') ||
            active ||
            document.body
          target.dispatchEvent(ev)
          return true
        } catch (e) {
          console.error('[dsh-snip-composer] dispatchPaste failed:', e)
          return false
        }
      }

      function runCapture(mode, label) {
        setOpen(false)
        if (busyRef.current) return
        busyRef.current = true
        setHint('正在' + label + '…')
        fetch(SNIP_ROUTE, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ mode: mode }),
        })
          .then(function (r) { return r.json() })
          .then(function (data) {
            if (!data || data.ok === false) {
              setHint('截图失败：' + (data && (data.error || data.reason) ? (data.error || data.reason) : '未知错误'))
            } else if (typeof data.imageB64 === 'string' && data.imageB64.length > 0) {
              var ok = dispatchPasteFromBase64(data.imageB64)
              setHint(ok ? '已截图，输入文字后发送' : '已截图，但自动粘贴失败——请手动 Ctrl+V')
            } else {
              // 老客户端/老服务端没回 imageB64（理论上不会），提示用户手动粘贴
              setHint('已截图，请手动 Ctrl+V 到对话框')
            }
          })
          .catch(function (err) {
            setHint('截图失败：' + (err && err.message ? err.message : String(err)))
          })
          .finally(function () {
            busyRef.current = false
            setTimeout(function () { setHint(null) }, 4000)
          })
      }

      function onMouseDown(e) {
        // 关键：阻止按钮抢走输入框焦点，否则截图完成后 Ctrl+V 粘不进对话框
        e.preventDefault()
      }

      var menu = open
        ? h(
            'div',
            {
              style: {
                position: 'absolute',
                bottom: '100%',
                left: 0,
                marginBottom: 6,
                background: 'var(--dsh-bg-elevated, #1e1e1e)',
                border: '1px solid var(--dsh-border, #3a3a3a)',
                borderRadius: 8,
                boxShadow: '0 6px 24px rgba(0,0,0,0.35)',
                padding: 4,
                zIndex: 9999,
                minWidth: 160,
              },
            },
            MENU_ITEMS.map(function (item) {
              return h(
                'button',
                {
                  key: item.key,
                  type: 'button',
                  onMouseDown: function (e) { e.preventDefault() },
                  onClick: function () { runCapture(item.key, item.label) },
                  style: {
                    display: 'block',
                    width: '100%',
                    textAlign: 'left',
                    border: 'none',
                    background: 'transparent',
                    color: 'inherit',
                    borderRadius: 6,
                    padding: '7px 12px',
                    cursor: 'pointer',
                    fontSize: 13,
                    lineHeight: '18px',
                  },
                },
                item.label,
              )
            }),
          )
        : null

      return h(
        'span',
        { ref: rootRef, style: { display: 'inline-flex', alignItems: 'center', marginRight: 6, position: 'relative' } },
        h(
          'button',
          {
            type: 'button',
            onMouseDown: onMouseDown,
            onClick: function () { setOpen(!open) },
            title: '截图提问：框选 / 隐藏后框选 / 全屏',
            style: {
              border: '1px solid var(--dsh-border, #3a3a3a)',
              background: 'transparent',
              color: 'inherit',
              borderRadius: 6,
              padding: '2px 8px',
              cursor: 'pointer',
              fontSize: 13,
              lineHeight: '20px',
            },
          },
          '📷 截图提问 ▾',
        ),
        menu,
        hint ? h('span', { style: { marginLeft: 6, fontSize: 12, opacity: 0.8 } }, hint) : null,
      )
    }

    function apply(ctx) {
      if (!ctx || !ctx.slots || typeof ctx.slots.inject !== 'function') return
      try {
        ctx.slots.inject('conversation.input.left', function () {
          return ctx.slots.register(
            {
              name: 'conversation.input.left',
              id: 'dsh-snip-composer-button',
              order: 6,
              inject: function () { return {} },
            },
            SnipButton,
          )
        })
      } catch (error) {
        console.error('[dsh-snip-composer] failed to register composer button:', error)
      }
    }

    exports.name = name
    exports.apply = apply
    exports.inject = ['slots']

    return module.exports
  },
})
