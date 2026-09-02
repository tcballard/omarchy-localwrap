# LocalWrap security boundary

LocalWrap is an unsandboxed Omarchy plugin that intentionally starts local
development servers. Repository manifests and process output are untrusted.
Version 0.3.0 places both behind the bundled `localwrap-helper`; QML does not
read manifests or launch manifest commands directly.

## Marketplace remediation evidence

| Review finding | Enforced boundary | Regression evidence |
|---|---|---|
| General execution through package/interpreter tools | Reject `npx`, `npm exec`, `deno`, eval flags, arbitrary interpreter paths, shell syntax, and non-exact package commands. Display exact resolved executable, cwd, and local package/script origin (including pre/post lifecycle scripts and content hashes); require one-time confirmation of a revalidated SHA-256 plan fingerprint. | `test_dangerous_command_shapes_are_rejected`, `test_exact_origin_change_invalidates_confirmation`, `test_interpreter_script_content_change_invalidates_confirmation` |
| Symlink escape | Resolve repository, cwd, package file, and interpreter script on disk and require every real path to remain inside the real repository. Manifest/package files cannot be symlinks. | `test_repository_symlink_cannot_select_outside_cwd`, `test_interpreter_script_symlink_cannot_escape` |
| Unbounded JSON/QML materialization | Cap bytes and scan JSON depth before decode; enforce strict schemas plus project/workspace/dependency/member and string/argument limits; return only bounded normalized JSON to QML. | `test_manifest_limits_apply_before_materialization`, `test_schema_and_string_limits_are_enforced`, `test_config_is_bounded_deduplicated_and_atomically_written` |
| Hostname probe boundary | Accept only numeric `127.0.0.1` or `[::1]` HTTP(S) URLs on explicit ports. | `test_numeric_loopback_only` and Node URL tests |
| Descendant process survival | Start every command with `start_new_session=True`; TERM the process group, wait two seconds, then KILL on Stop/unload/interruption or natural leader exit. | `test_term_cleans_descendant_process_group`, `test_natural_parent_exit_also_cleans_descendants` |
| Unbounded live output | Drain in 4 KiB chunks; forward at most 64 KiB and 2 KiB per line before QML; retain only 20 bounded lines. | `test_output_is_capped_before_qml_receives_it`, Node tail test |
| Rich-text interpretation | All QML `Text` instances use the `SafeText` component with `Text.PlainText`. | Static QML gate in `tests/run` |
| Unsafe installer replacement | Reject symlinks/collisions, stage a fixed complete payload, verify SHA-256 file equality, set fixed modes, atomically rename, and restore the prior directory on failed swap. | Installer lifecycle in `tests/run` |
| Manual repository setup | Add/remove repositories in the panel; the helper writes the bounded configuration atomically with mode `0600`. | `test_config_is_bounded_deduplicated_and_atomically_written` |

## Reporting

Please use GitHub's private vulnerability-reporting flow for security issues.
Do not include private repository manifests, paths, package scripts, or process
output in a public report.
