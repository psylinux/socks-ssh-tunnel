# SOCKS-via-SSH

A lightweight Bash script to manage a SOCKS5 proxy over an SSH tunnel. It features a supervisor loop that automatically restarts the tunnel if it drops, background execution, and easy process management.

## Features

- **SOCKS5 Proxy**: Provides a local SOCKS5 proxy via SSH dynamic forwarding (`ssh -D`).
- **Auto-Restart**: A supervisor loop monitors the connection and restarts it with exponential backoff if it fails.
- **Background Mode**: Runs in the background using `nohup` and `disown`, allowing you to close your terminal.
- **Easy Management**: Simple commands to start, stop, restart, and check status.
- **Logging**: Keeps track of tunnel activity and SSH output in a dedicated log file.

## Prerequisites

- `ssh` client installed.
- Access to a remote SSH server.
- `lsof` (optional, used for better port-in-use detection).

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/psylinux/socks-via-ssh.git
   cd socks-via-ssh
   ```
2. Make the script executable:
   ```bash
   chmod +x socks-via-ssh.sh
   ```

## Usage

### Commands

| Command                      | Description                                     |
| :--------------------------- | :---------------------------------------------- |
| `./socks-via-ssh.sh start`   | Starts the tunnel supervisor in the background. |
| `./socks-via-ssh.sh stop`    | Stops the supervisor and the tunnel.            |
| `./socks-via-ssh.sh status`  | Checks if the supervisor is currently running.  |
| `./socks-via-ssh.sh restart` | Restarts the tunnel.                            |
| `./socks-via-ssh.sh logs`    | Tails the tunnel log file.                      |

### Configuration

You can override the default configuration using environment variables:

| Variable         | Default                   | Description                        |
| :--------------- | :------------------------ | :--------------------------------- |
| `SSH_HOST`       | `dark-horse`              | Remote SSH server address.         |
| `SSH_USER`       | `cowboy`                  | SSH username.                      |
| `SSH_PORT`       | `2222`                    | Remote SSH port.                   |
| `SOCKS_HOST`     | `127.0.0.1`               | Local address for the SOCKS proxy. |
| `SOCKS_PORT`     | `1080`                    | Local port for the SOCKS proxy.    |
| `ALIVE_INTERVAL` | `60`                      | `ServerAliveInterval` in seconds.  |
| `ALIVE_COUNTMAX` | `3`                       | `ServerAliveCountMax`.             |
| `STATE_DIR`      | `$HOME/.socks-ssh-tunnel` | Directory for PID and log files.   |

### Example

Start the tunnel with custom settings:
```bash
SSH_HOST=my-remote-server SSH_USER=myuser SOCKS_PORT=9050 ./socks-via-ssh.sh start
```

## Browser Configuration (Firefox)

To use your new SOCKS5 proxy in Firefox:

1. Open **Settings** and search for **Network Settings**.
2. Click **Settings...** and select **Manual proxy configuration**.
3. Set **SOCKS Host** to `127.0.0.1` and **Port** to `1080` (or your custom `SOCKS_PORT`).
4. Ensure **SOCKS v5** is selected.
5. Check the box **Proxy DNS when using SOCKS v5** (this ensures DNS queries are also tunneled).

## How It Works

1. **Supervisor**: When you run `start`, the script launches a "run_loop" in the background.
2. **Persistence**: The loop continuously attempts to run `ssh -N -D ...`. If the `ssh` process exits (e.g., due to network failure), the loop waits and restarts it.
3. **Graceful Stop**: Running `stop` creates a stop flag file and sends a signal to the supervisor to terminate cleanly.

## License

MIT License
