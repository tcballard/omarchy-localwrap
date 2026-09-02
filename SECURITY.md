# LocalWrap security boundary

LocalWrap is an unsandboxed Omarchy plugin that intentionally starts local
development servers. Repository manifests and process output are untrusted.
Version 0.3.1 places both behind the bundled `localwrap-helper`; QML does not
read manifests or launch manifest commands directly.

## Marketplace remediation evidence

| Review finding | Enforced boundary | Regression evidence |
|---|---|---|
| General execution through package/interpreter tools | Reject `npx`, `npm exec`, `deno`, eval flags, arbitrary interpreter paths, shell syntax, and non-exact package commands. Display exact resolved executable, cwd, and local package/script origin (including pre/post lifecycle scripts and content hashes); require one-time confirmation of a revalidated SHA-256 plan fingerprint. | `test_dangerous_command_shapes_are_rejected`, `test_exact_origin_change_invalidates_confirmation`, `test_interpreter_script_content_change_invalidates_confirmation` |
| Origin/cwd check-then-use | Decode and hash manifest/package data from the same held read. Pin the executable and cwd by descriptor and fingerprint their identities. Execute interpreter bytes from a sealed `memfd`; execute package lifecycle strings from the held package snapshot without reopening `package.json`. | `test_manifest_fields_and_digest_share_one_read_snapshot`, `test_package_fields_and_digest_share_one_read_snapshot`, `test_interpreter_executes_sealed_snapshot_after_path_mutation`, `test_working_directory_descriptor_survives_path_replacement`, `test_package_execution_never_reopens_changed_package_json` |
| Symlink escape | Open repository descendants component-by-component with `O_NOFOLLOW`; retain the selected cwd descriptor through launch. | `test_repository_symlink_cannot_select_outside_cwd`, `test_interpreter_script_symlink_cannot_escape`, `test_working_directory_descriptor_survives_path_replacement` |
| Unbounded JSON/QML materialization | Cap bytes and scan JSON depth before decode; enforce strict schemas plus project/workspace/dependency/member and string/argument limits; return only bounded normalized JSON to QML. | `test_manifest_limits_apply_before_materialization`, `test_schema_and_string_limits_are_enforced`, `test_config_is_bounded_deduplicated_and_atomically_written` |
| Hostname probe boundary | Accept only numeric `127.0.0.1` or `[::1]` HTTP(S) URLs on explicit ports. | `test_numeric_loopback_only` and Node URL tests |
| Descendant process survival | Start every command with `start_new_session=True`; TERM the process group, wait two seconds, then KILL on Stop/unload/interruption or natural leader exit. | `test_term_cleans_descendant_process_group`, `test_natural_parent_exit_also_cleans_descendants` |
| Unbounded live output | Drain in 4 KiB chunks; forward at most 64 KiB and 2 KiB per line before QML; retain only 20 bounded lines. | `test_output_is_capped_before_qml_receives_it`, Node tail test |
| Rich-text interpretation | All QML `Text` instances use the `SafeText` component with `Text.PlainText`. | Static QML gate in `tests/run` |
| Unsafe installer replacement | Verify the HOME-to-plugin ancestor chain with no-follow descriptors and user ownership; lock one held parent; stage a fixed SHA-256-verified payload; commit with descriptor-relative `renameat2(NOREPLACE/EXCHANGE)`; verify exchanged identities and reverse a failed/displaced exchange before backup deletion. | `test_install_noreplace_refuses_concurrent_destination_without_nesting` plus collision, ancestor-symlink, first-install, and replacement lifecycle gates in `tests/run` |
| Manual repository setup | Add/remove repositories in the panel; the helper writes the bounded configuration atomically with mode `0600`. | `test_config_is_bounded_deduplicated_and_atomically_written` |

## Reporting

Please use GitHub's private vulnerability-reporting flow for security issues.
Do not include private repository manifests, paths, package scripts, or process
output in a public report.
