// dsh-snip-composer — Node (host) half.
// Registers ONE HTTP route the browser button calls:
//   POST /_dsh/snip-composer/capture
// which launches the bundled PowerShell region-capture overlay, copies the
// selected region to the clipboard, focuses the DSH window and pastes it into
// the composer (Ctrl+V) — the user then types and sends manually.
//
// The route is local-only (same-origin / loopback). The browser button can
// call it with fetch() because it lives under /_dsh just like vision-router's
// own routes.

import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readFile, unlink } from 'node:fs/promises'

const execFileAsync = promisify(execFile)

const HERE = path.dirname(fileURLToPath(import.meta.url))
// The region-capture script lives next to this file (lib/snip.ps1).
const SNIP_SCRIPT = path.join(HERE, 'snip.ps1')

const PLUGIN_ID = 'snip-composer'

export const name = PLUGIN_ID
export const inject = ['webServer']

function json(res, status, body, headers = {}) {
  res.writeHead(status, {
    'content-type': 'application/json',
    ...headers,
  })
  res.end(JSON.stringify(body))
}

// 'diag' 是排障模式：不弹窗，抓全屏诊断图并回报 DPI 缩放比。
const ALLOWED_MODES = new Set(['region', 'fullscreen', 'hide-region', 'diag'])

function captureWithPowershell(mode = 'region', timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    // -STA so the Windows Forms clipboard / screen APIs work. windowsHide keeps
    // the console invisible without suppressing WinForms dialogs. DO NOT add
    // -NonInteractive: it makes PowerShell skip the region-select overlay.
    const safeMode = ALLOWED_MODES.has(mode) ? mode : 'region'
    const child = execFile(
      'powershell.exe',
      [
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-File', SNIP_SCRIPT,
        '-Mode', safeMode,
      ],
      {
        windowsHide: true,
        timeout: timeoutMs,
        maxBuffer: 1024 * 1024,
      },
      (error, stdout, stderr) => {
        if (error) {
          const wrapped = new Error(
            `snip-composer: capture failed (${error.message})`,
          )
          wrapped.code = 'SNIP_CAPTURE_FAILED'
          wrapped.cause = error
          wrapped.stderr = stderr
          reject(wrapped)
          return
        }
        // The script prints a single JSON line on success.
        const line = String(stdout || '').trim().split('\n').pop() || '{}'
        let parsed = {}
        try {
          parsed = JSON.parse(line)
        } catch {
          parsed = { ok: true, raw: line }
        }
        resolve(parsed)
      },
    )
    // Surface timeout / kill explicitly.
    child.on('error', (err) => reject(err))
  })
}

export function apply(ctx, config = {}) {
  if (!ctx || typeof ctx.inject !== 'function') return
  ctx.inject(['webServer'], (webCtx) => {
    webCtx.effect(
      () => webCtx.webServer.register({
        kind: 'exact',
        path: '/_dsh/snip-composer/capture',
        handler: async (req, res) => {
          if (req.method !== 'POST') {
            res.setHeader('Allow', 'POST')
            res.writeHead(405)
            res.end()
            return
          }
          const fetchSite = String(req.headers?.['sec-fetch-site'] ?? '')
          if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') {
            json(res, 403, { ok: false, error: 'cross-origin capture rejected' })
            return
          }
          // 从请求体读取 mode：region / fullscreen / hide-region / diag
          let mode = 'region'
          try {
            const chunks = []
            for await (const chunk of req) chunks.push(chunk)
            const body = Buffer.concat(chunks).toString('utf8')
            if (body) {
              const parsed = JSON.parse(body)
              if (typeof parsed?.mode === 'string') mode = parsed.mode
            }
          } catch {
            /* 空 body 或缺省：走默认 region */
          }
          try {
            const result = await captureWithPowershell(mode, 60000)
            const payload = result ?? { ok: true }
            // 若 PS 把截图写成了临时文件，则读回归 base64（避免 base64 走 stdout
            // 被 maxBuffer 限制），随即删除临时文件，并把 base64 透传给浏览器端。
            // 浏览器端用 DataTransfer + ClipboardEvent 派发 paste，100% 可靠且不
            // 依赖全局焦点（修复 bug1）。
            if (payload && typeof payload.imagePath === 'string') {
              try {
                const buf = await readFile(payload.imagePath)
                payload.imageB64 = buf.toString('base64')
              } catch (readErr) {
                payload.ok = false
                payload.error = 'read temp png failed: ' + (readErr && readErr.message ? readErr.message : String(readErr))
              } finally {
                try { await unlink(payload.imagePath) } catch { /* 忽略删除失败 */ }
                delete payload.imagePath
              }
            }
            json(res, 200, payload, { 'cache-control': 'no-store' })
          } catch (error) {
            json(res, 500, {
              ok: false,
              error: error && error.message ? error.message : String(error),
              stderr: error?.stderr ? String(error.stderr).slice(0, 2000) : undefined,
            })
          }
        },
      }),
      'snip-composer: capture route',
    )
  })
}

export default { name, inject, apply }
