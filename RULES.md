# RULES

## Internationalization

Decision: **enabled**, **prepare** phase. Owner: Peter Marreck, 2026-09-29.

`--lang` and `DIFZ_LANG` (then `LANG`) select a locale from the 50-code
baseline. `--hilfe` is the German `--help` alias and infers `de`. English
is complete. Other catalogs are missing: warn `WARN: i18n missing-locale
<code>` and continue in English. Do not flip to enforce until UI strings
are extracted into a typed catalog.
