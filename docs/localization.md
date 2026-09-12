# Language support

SD Import (direct download) and SD Card Import (Mac App Store) support:

| Language | Locale |
| --- | --- |
| English | `en` |
| Simplified Chinese | `zh-Hans` |
| Traditional Chinese | `zh-Hant` |
| Japanese | `ja` |
| Korean | `ko` |
| German | `de` |
| French | `fr` |
| Spanish | `es` |
| Portuguese (Brazil) | `pt-BR` |
| Italian | `it` |

The app follows the preferred supported language configured in macOS, including
its per-app language preference. Quit and reopen the app after changing that
preference. English is the development language and fallback. Regional matching
follows macOS: for example, Mexican Spanish uses Spanish, and Hong Kong Chinese
uses Traditional Chinese. Portuguese is currently the Brazilian variant only.

The background helper records stable messages. The app translates them when
displaying helper errors, so they follow the app's language even when the
helper runs with a different system language.

Import, history, settings, onboarding, purchase dialogs, native file-panel
instructions, accessibility labels, and app-generated status/error messages use
the same shared translations. Dates, byte counts, and durations use Foundation
formatters. App and product names, filenames, folder paths, saved identifiers,
and machine-readable report schemas retain their original values. Recognized legacy
error codes are translated for display; other previously recorded error text is
preserved as recorded. New copy failures are saved in the active language.
Changing languages does not rename imported folders or
reset import history.

## Maintaining translations

Resources live in
`SDImport/Packages/SDImportCore/Sources/SDImportCore/Resources/<locale>.lproj`.
Each locale has `Localizable.strings` and `Localizable.stringsdict`.

Use `L10n.tr("A message")` for native presentation text, including text passed
through a plain `String` to a view or native panel. Use complete interpolated
sentences so translators can change word order. The parameter is Foundation's
`String.LocalizationValue`; interpolation retains argument types. Translation
values use positional placeholders such as `%1$@` and `%2$lld`. Never translate
persisted identifiers, user-provided strings, filesystem paths, or raw enum
values. `L10n.storedMessage` translates only explicitly recognized legacy
messages and passes other values through unchanged.

Keep English keys and argument types identical across catalogs. Count messages
in `Localizable.stringsdict` use native plural rules. Add matching entries to all
locales when adding a message. Swift's `-emit-localized-strings` build option can
extract the precise keys and placeholder types into `.stringsdata` files.

The Swift package processes the shared bundle automatically. The direct-build
script copies that bundle into both the app and its login helper. Xcode embeds
it through the shared package dependency for the App Store edition. The helper
embedding step runs on every build so resource-only changes reach its nested
bundle during incremental builds. Both app
and helper Info plists advertise the supported languages.

## Verification

```bash
python3 script/check_localizations.py
swift test --package-path SDImport/Packages/SDImportCore --filter LocalizationTests
swift test --package-path SDImport/Packages/SDImportCore
```

After building either edition, verify its actual shipped resources:

```bash
python3 script/check_localization_bundles.py "/path/to/SD Import.app"
python3 script/check_localization_bundles.py "/path/to/SD Card Import.app"
```

The bundle checker creates an isolated Foundation-only executable using the
actual localization helper and a copy of the packaged resources. It checks
both the app and helper across all languages, regional preferences, fallback,
pluralization, and interpolated paths. It also compares every shipped catalog
with the current source. It fails if lookup needs build-directory
resources. It does not launch the importer or access mounted cards.

For isolated direct-build validation, set `SDIMPORT_DIST_DIR` to a disposable
output directory and `SDIMPORT_SKIP_STOP=1` to leave any running app alone.

Automated checks do not replace full UI layout inspection or native-speaker
review of wording. Store product names and prices are supplied by StoreKit;
App Store listing and product metadata localization are managed separately.
