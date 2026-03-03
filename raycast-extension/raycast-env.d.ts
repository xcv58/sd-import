/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** sd-import Path - Absolute path to the sd-import launcher */
  "launcherPath": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `auto-import` command */
  export type AutoImport = ExtensionPreferences & {}
  /** Preferences accessible in the `retry-latest` command */
  export type RetryLatest = ExtensionPreferences & {}
  /** Preferences accessible in the `manual-volume-import` command */
  export type ManualVolumeImport = ExtensionPreferences & {}
  /** Preferences accessible in the `jobs-dashboard` command */
  export type JobsDashboard = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `auto-import` command */
  export type AutoImport = {
  /** Optional location label */
  "location": string
}
  /** Arguments passed to the `retry-latest` command */
  export type RetryLatest = {}
  /** Arguments passed to the `manual-volume-import` command */
  export type ManualVolumeImport = {
  /** Optional location label */
  "location": string
}
  /** Arguments passed to the `jobs-dashboard` command */
  export type JobsDashboard = {}
}

