# Hardware compatibility

`fanctl diagnostics` and the menu bar **Hardware diagnostics…** item report what
the current Mac exposes through AppleSMC. The report reads SMC metadata and
values only; it never writes a fan mode or target.

## Validation matrix

| Mac model | macOS | Temperature and fan reads | Fan target writes | Evidence |
| --- | --- | --- | --- | --- |
| MacBook Pro M5 Max (`Mac17,7`) | 27.0.1 | Verified | Verified | Project hardware runs recorded in the fannier project notes; all three profiles held targets, and automatic mode was restored after shutdown. |
| Other Mac models and macOS versions | Any | Undetermined | Undetermined | A diagnostics report can show detected keys and encodings, but detection alone is not a hardware validation. |

The report marks a configuration as matching the documented test setup only
when both `hw.model` is `Mac17,7` and the macOS version is `27.0.1`. This label
does not imply validation of a different build or later OS release.

## Readiness fields

- **Detected SMC write-key layout** means every reported fan has a one-byte
  `ui8 ` mode key and a target key with a known `flt ` or `fpe2` encoding.
- **Write validation** reports whether the Mac and OS match the configuration
  with recorded hardware testing.
- A detected key layout does not prove that a privileged write will be
  accepted. The report does not attempt one; use the report as a compatibility
  indicator, not as a safety guarantee.

## Report commands

```sh
fanctl diagnostics
fanctl diagnostics --json
```

Both commands work without the root daemon and do not need administrator
privileges. The JSON form is intended for support reports and tooling.
