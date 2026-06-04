# bootstrap

One-command Mac bootstrap for DevSpace git auth.

```bash
curl -fsSL https://raw.githubusercontent.com/apptivity-lab/bootstrap/main/bootstrap.sh | bash
```

Mints a GitHub App installation token inline — no existing checkout needed — uses
it to clone [`devspace`](https://github.com/apptivity-lab/devspace) and run its
`install.sh`, after which the git credential helper is self-sustaining.

You'll be prompted for your App ID, installation ID, and private key (1Password
`op read`, a local path, or pasted). The script contains **no secrets**.
