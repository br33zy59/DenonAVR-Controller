# Denon AVR Controller

Small Windows GUI for controlling a Denon or Marantz network receiver over the classic ASCII **TCP port 23** control channel (often described as Telnet-like).

## Layout

| Path | Description |
|------|--------------|
| `src/DenonAVR.standalone.ps1` | Source script |
| `assets/DenonAVR.ico` | Application icon |
| `scripts/Build.ps1` | Builds `release/DenonAVR.exe` with [ps2exe](https://github.com/MScholtes/PS2EXE) |

The `release/` folder (and `.exe` files) are intentionally **ignored by Git**.

## Requirements

- Windows PowerShell 5.1
- [.NET Framework](https://dotnet.microsoft.com/download/dotnet-framework) (WinForms assemblies load at runtime)

## Run without building

From the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\DenonAVR.standalone.ps1
```

Ensure no other application has the receiver’s TCP control session open at the same time (many units allow only **one** client).

## Build a standalone `.exe`

1. Install ps2exe (once):

   ```powershell
   Install-Module ps2exe -Scope CurrentUser -Repository PSGallery -Force
   ```

2. From the repo root:

   ```powershell
   .\scripts\Build.ps1
   ```

The executable is written to `release\DenonAVR.exe`.

## Publishing to GitHub

If GitHub CLI is installed and authenticated:

```powershell
gh auth login
gh repo create DenonAVR-Controller --public --source=. --remote=origin --push
```

If you prefer the web UI, create an empty repository, then:

```powershell
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git
git push -u origin main
```

## Disclaimer

This is unofficial hobby software—not affiliated with Sound United, Denon, or Marantz. Use at your own risk.
