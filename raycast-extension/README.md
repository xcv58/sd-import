# Raycast Extension: SD Import

This local extension wraps `$HOME/work/macos-automation/sd-import`.

## Commands

- `SD Import Auto`: run auto flow (`sd-import auto [location]`)
- `SD Import Select Volume`: manually pick a currently mounted removable volume and run `import` flow or `scan` only
- `SD Import Retry Latest`: run (`sd-import retry-latest`)
- `SD Import Jobs`: list jobs with actions (`import`, `retry`, `run auto`, `open report`)

## Install Locally

1. Open Raycast command: `Import Extension`
2. Select this folder:
   `$HOME/work/macos-automation/raycast-extension`
3. In extension preferences, confirm `sd-import Path`:
   `$HOME/work/macos-automation/sd-import`

## Dev

```bash
cd $HOME/work/macos-automation/raycast-extension
npm install
npm run dev
```
