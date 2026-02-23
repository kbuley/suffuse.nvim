# suffuse.nvim

Neovim plugin for [suffuse](https://github.com/kbuley/suffuse) — shared clipboard over TCP.

The primary use case is Neovim running inside a **container or remote machine**, sharing a clipboard with the host and any other connected peers. The plugin auto-probes `host.docker.internal` and `host.containers.internal` so it works out of the box with Docker and Podman without any configuration.

## Requirements

- Neovim ≥ 0.9 built with LuaJIT (standard on all supported platforms)
- OpenSSL shared library (`libssl`) available at runtime
- A running `suffuse server` on the host (see [suffuse](https://github.com/kbuley/suffuse))

## How it works

The plugin connects to the suffuse gRPC-gateway over **HTTPS/TLS** on the same port as the gRPC server. It maintains a persistent streaming `GET /v1/watch` connection to receive clipboard updates in real time, and opens short-lived connections for `POST /v1/copy` and `GET /v1/status`.

TLS is implemented via LuaJIT FFI calling directly into OpenSSL — no external binaries, no shell-out, no compiled Neovim extensions required.

## Installation

Works out of the box with no configuration:

```lua
-- lazy.nvim
{ 'kbuley/suffuse.nvim' }
```

With options:

```lua
{
  'kbuley/suffuse.nvim',
  opts = {
    host  = '192.168.1.10',  -- skip auto-probe, connect directly
    token = 'mysecret',
    yank  = { register = '+' },
  },
}
```

## Configuration

All options are optional. These are the defaults:

```lua
require('suffuse').setup({
  host         = nil,    -- nil = auto-probe (see below)
  port         = 8752,
  token        = '',     -- empty = use default encryption, no bearer auth
  auto_connect = true,   -- connect on VimEnter

  -- Yank: send local yanks to the server
  yank = {
    enable   = true,   -- register TextYankPost autocmd
    register = '"',    -- '"' | '+' | '*' | 'prompt'
  },

  -- Paste: where incoming updates land
  paste = {
    registers = { '+', '*' },
  },
})
```

### `yank.register` values

| Value | Behaviour |
|-------|-----------|
| `'"'` | Unnamed register — captures every yank and delete (default) |
| `'+'` | System clipboard register only |
| `'*'` | Primary selection register only |
| `'prompt'` | Ask via `vim.ui.select()` on every yank |

### Host auto-probe

When `host` is `nil`, the plugin tries each of the following in order and uses the first that accepts a TCP connection:

1. `host.docker.internal` — Docker Desktop (macOS, Windows, Docker Desktop Linux)
2. `host.containers.internal` — Podman rootless
3. `localhost` — running directly on the host

Once resolved, the host is remembered for the session. Reconnects skip the probe.

### Token / authentication

The `token` maps directly to the `--token` flag on the suffuse server. When set, it is sent as `Authorization: Bearer <token>` on every request. Traffic is always TLS-encrypted regardless of whether a token is set.

## Commands

| Command | Description |
|---------|-------------|
| `:SuffuseConnect` | Connect (or reconnect) to the server |
| `:SuffuseDisconnect` | Disconnect and stop reconnecting |
| `:SuffuseStatus` | Show connection state and peer list |
| `:SuffuseCopy [reg]` | Send a register to the shared clipboard |
| `:SuffusePaste` | Pull from server and insert at cursor |

## Suggested keymaps

suffuse.nvim sets no keymaps by default.

```lua
vim.keymap.set({ 'n', 'v' }, '<leader>sc', '<cmd>SuffuseCopy<cr>',
  { desc = 'suffuse: copy to shared clipboard' })

vim.keymap.set('n', '<leader>sp', '<cmd>SuffusePaste<cr>',
  { desc = 'suffuse: paste from shared clipboard' })

vim.keymap.set('n', '<leader>ss', '<cmd>SuffuseStatus<cr>',
  { desc = 'suffuse: show status' })
```

## Disabling auto-setup

```lua
vim.g.suffuse_no_autosetup = true
```

## Notes

- **Text only** — `text/plain` MIME type. Images are intentionally filtered out.
- **TLS** — all traffic is encrypted. The server uses a certificate derived from the shared passphrase/token. The plugin uses `SSL_VERIFY_NONE` since it cannot reproduce the HKDF key derivation to verify the cert; the Bearer token provides authentication.
- **Reconnects automatically** with exponential backoff (1s → 2s → 4s → … → 30s cap).
