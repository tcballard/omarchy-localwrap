// Model.js — pure logic for the LocalWrap Omarchy plugin.
//
// This file ports the LocalWrap workspace-manifest v1 contract and its safety
// boundaries (command allowlist, loopback-only URLs, strict unknown-field
// rejection) from the macOS app's Swift services to portable JavaScript:
//
//   Sources/Services/CommandService.swift            -> parseCommand
//   Sources/Services/ProjectValidationService.swift  -> validateLoopbackURL
//   Sources/Services/HealthCheckResolver.swift       -> resolveHealthCheck
//   Sources/Services/ReadinessService.swift          -> readiness constants
//   Sources/Services/WorkspacePackService.swift      -> slugify / uniqueSlug
//   Documentation/workspace-manifest-v1.md           -> parseWorkspaceManifest
//
// It is imported by BarWidget.qml / Panel.qml (Qt's JS engine, ~ES2016 — no
// optional chaining, nullish coalescing, or Unicode property escapes here)
// and by tests/model.test.js under node via the module-export guard at the
// bottom. Keep every function pure: no I/O, no timers, no Qt or node APIs.

var ALLOWED_EXECUTABLES = [
    "npm", "npx", "yarn", "pnpm", "node", "bun", "python", "python3", "deno",
];

var ALLOWED_URL_HOSTS = ["localhost", "127.0.0.1", "::1"];

var MIN_PORT = 1000;
var MAX_PORT = 65535;
var DEFAULT_PORT = 3000;

// Readiness contract mirrored from RuntimeService/ReadinessService:
// poll every 500 ms for up to 30 s; each probe is a HEAD request with a
// 1 second budget; any HTTP status below 500 counts as ready.
var READY_POLL_INTERVAL_MS = 500;
var READY_TIMEOUT_MS = 30000;
var PROBE_TIMEOUT_SECONDS = 1;

var MANIFEST_RELATIVE_PATHS = [".localwrap/workspace.json", "localwrap.json"];

var ROOT_FIELDS = ["localwrap", "name", "projects", "workspaces"];
var PROJECT_FIELDS = [
    "id", "name", "path", "command", "port", "url",
    "autostart", "openOnReady", "dependsOn", "healthCheck",
];
var WORKSPACE_FIELDS = ["id", "name", "projects"];
var HEALTH_CHECK_FIELDS = ["path", "url"];

var STATUS = {
    stopped: "stopped",
    starting: "starting",
    ready: "ready",
    stalled: "stalled",
    stopping: "stopping",
    failed: "failed",
    conflict: "conflict",
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function isString(value) {
    return typeof value === "string";
}

function isNonEmptyString(value) {
    return isString(value) && /\S/.test(value);
}

function isBoolean(value) {
    return typeof value === "boolean";
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function contains(list, value) {
    return list.indexOf(value) !== -1;
}

function basename(path) {
    var trimmed = String(path).replace(/\/+$/, "");
    var index = trimmed.lastIndexOf("/");
    return index === -1 ? trimmed : trimmed.slice(index + 1);
}

// ---------------------------------------------------------------------------
// Command parsing (CommandParser)
// ---------------------------------------------------------------------------

var FORBIDDEN_COMMAND_CHARACTERS = /[;&|$`><(){}\[\]!#*?~%^"'\r\n]/;

function parseCommand(input) {
    var command = isString(input) ? input.trim() : "";
    if (command === "") {
        return { ok: false, error: "Command is empty." };
    }
    if (FORBIDDEN_COMMAND_CHARACTERS.test(command)) {
        return {
            ok: false,
            error: "Command contains shell operators or other disallowed characters.",
        };
    }
    var tokens = command.split(/\s+/);
    var executable = tokens[0];
    if (!contains(ALLOWED_EXECUTABLES, executable)) {
        return {
            ok: false,
            error: "Executable \"" + executable + "\" is not allowed. Allowed: "
                + ALLOWED_EXECUTABLES.join(" ") + ".",
        };
    }
    return {
        ok: true,
        executable: executable,
        arguments: tokens.slice(1),
        argv: tokens.slice(),
    };
}

function formatCommand(parsed) {
    return parsed.argv.join(" ");
}

// ---------------------------------------------------------------------------
// Loopback URL validation (LocalURLValidator)
// ---------------------------------------------------------------------------

// Accepts only http(s) URLs whose host is localhost, 127.0.0.1, or [::1],
// with no userinfo and an explicit port between 1000 and 65535.
function validateLoopbackURL(value) {
    if (!isNonEmptyString(value)) {
        return { ok: false, error: "URL is empty." };
    }
    var match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([/?#][\s\S]*)?$/.exec(value.trim());
    if (!match) {
        return { ok: false, error: "URL must look like http://localhost:<port>." };
    }
    var scheme = match[1].toLowerCase();
    if (scheme !== "http" && scheme !== "https") {
        return { ok: false, error: "URL scheme must be http or https." };
    }
    var authority = match[2];
    if (authority.indexOf("@") !== -1) {
        return { ok: false, error: "URL must not contain user information." };
    }
    var host = "";
    var portText = null;
    var bracket = /^\[([^\]]*)\](?::(\d*))?$/.exec(authority);
    if (bracket) {
        host = bracket[1];
        portText = bracket[2] === undefined ? null : bracket[2];
    } else {
        var colon = authority.lastIndexOf(":");
        if (colon === -1) {
            host = authority;
        } else {
            host = authority.slice(0, colon);
            portText = authority.slice(colon + 1);
        }
        if (host.indexOf(":") !== -1) {
            // IPv6 literals must use the bracketed [::1] form.
            return { ok: false, error: "URL host must be localhost, 127.0.0.1, or [::1]." };
        }
    }
    host = host.toLowerCase();
    if (!contains(ALLOWED_URL_HOSTS, host)) {
        return {
            ok: false,
            error: "URL host must be localhost, 127.0.0.1, or [::1].",
        };
    }
    if (portText === null || portText === "" || !/^\d+$/.test(portText)) {
        return { ok: false, error: "URL must include an explicit port." };
    }
    var port = parseInt(portText, 10);
    if (port < MIN_PORT || port > MAX_PORT) {
        return {
            ok: false,
            error: "URL port must be between " + MIN_PORT + " and " + MAX_PORT + ".",
        };
    }
    var rest = match[3] === undefined ? "" : match[3];
    var path = rest;
    var query = null;
    var fragment = null;
    var hashIndex = path.indexOf("#");
    if (hashIndex !== -1) {
        fragment = path.slice(hashIndex + 1);
        path = path.slice(0, hashIndex);
    }
    var queryIndex = path.indexOf("?");
    if (queryIndex !== -1) {
        query = path.slice(queryIndex + 1);
        path = path.slice(0, queryIndex);
    }
    var hostForHref = host === "::1" ? "[::1]" : host;
    var origin = scheme + "://" + hostForHref + ":" + port;
    return {
        ok: true,
        scheme: scheme,
        host: host,
        port: port,
        path: path,
        query: query,
        fragment: fragment,
        origin: origin,
        href: origin + rest,
    };
}

// ---------------------------------------------------------------------------
// Health check resolution (HealthCheckResolver)
// ---------------------------------------------------------------------------

function resolveHealthCheck(projectURL, healthCheck) {
    if (healthCheck !== null && healthCheck !== undefined) {
        var path = isString(healthCheck.path) ? healthCheck.path.trim() : "";
        var explicitURL = isString(healthCheck.url) ? healthCheck.url.trim() : "";
        if ((path !== "") === (explicitURL !== "")) {
            return { ok: false, error: "Health check must contain either a path or a URL." };
        }
        if (explicitURL !== "") {
            var validated = validateLoopbackURL(explicitURL);
            if (!validated.ok) {
                return { ok: false, error: "Health check URL must be local http(s) on an allowed port." };
            }
            return { ok: true, url: validated.href };
        }
        if (path.charAt(0) !== "/") {
            return { ok: false, error: "Health check path must start with /." };
        }
        var base = validateLoopbackURL(projectURL);
        if (!base.ok) {
            return { ok: false, error: "Project URL is not a valid local URL." };
        }
        // The path replaces the project URL's path; query strings and
        // fragments from the project URL are not carried over.
        return { ok: true, url: base.origin + path };
    }
    var projectValidated = validateLoopbackURL(projectURL);
    if (!projectValidated.ok) {
        return { ok: false, error: "Project URL is not a valid local URL." };
    }
    return { ok: true, url: projectValidated.href };
}

// ---------------------------------------------------------------------------
// Identifier slugs (WorkspacePackService.slug / uniqueSlug)
// ---------------------------------------------------------------------------

// The macOS app maps every non-alphanumeric character to "-" using Unicode
// alphanumerics; this port is ASCII-only, which is identical for the ASCII
// identifiers the manifest guide recommends.
function slugify(value) {
    var collapsed = String(value)
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
    return collapsed === "" ? "item" : collapsed;
}

function uniqueSlug(value, used) {
    var root = slugify(value);
    var candidate = root;
    var suffix = 2;
    while (used[candidate] === true) {
        candidate = root + "-" + suffix;
        suffix += 1;
    }
    used[candidate] = true;
    return candidate;
}

// ---------------------------------------------------------------------------
// Relative path validation (lexical port of the review's containment rule)
// ---------------------------------------------------------------------------

// The macOS app resolves "." components and symlinks on disk and requires the
// result to stay inside the repository root. Without filesystem access this
// port applies the lexical half: relative only, and ".." may never climb
// above the repository root.
function validateRelativePath(value) {
    if (!isNonEmptyString(value)) {
        return { ok: false, error: "Path must be a non-empty string." };
    }
    var path = value.trim();
    if (path.charAt(0) === "/") {
        return { ok: false, error: "Path must be relative to the repository root." };
    }
    var segments = path.split("/");
    var depth = 0;
    for (var i = 0; i < segments.length; i += 1) {
        var segment = segments[i];
        if (segment === "" || segment === ".") {
            continue;
        }
        if (segment === "..") {
            depth -= 1;
            if (depth < 0) {
                return { ok: false, error: "Path escapes the repository root." };
            }
        } else {
            depth += 1;
        }
    }
    return { ok: true, path: path };
}

function joinPath(root, relative) {
    var base = String(root).replace(/\/+$/, "");
    if (relative === "." || relative === "" || relative === "./") {
        return base;
    }
    return base + "/" + String(relative).replace(/^\.\//, "").replace(/\/+$/, "");
}

// ---------------------------------------------------------------------------
// Workspace manifest v1 parsing
// ---------------------------------------------------------------------------

function makeDiagnostic(code, scope, message) {
    return { code: code, scope: scope, message: message };
}

// Parses and validates one workspace manifest document. Never executes
// anything and never trusts unknown fields: exactly like the app's review,
// unrecognised root or item fields are blockers, which keeps the versioned
// contract explicit and refuses secret-bearing extensions such as
// "environment" or "tokens".
//
// Returns:
//   {
//     ok, errors, warnings, name,
//     projects:   [{ id, name, path, command, commandLine, port, url,
//                    autostart, openOnReady, dependsOn, healthCheckURL }],
//     workspaces: [{ id, name, projects }],
//   }
function parseWorkspaceManifest(text, fallbackName) {
    var errors = [];
    var warnings = [];
    var result = {
        ok: false,
        errors: errors,
        warnings: warnings,
        name: isNonEmptyString(fallbackName) ? fallbackName.trim() : "Workspace",
        projects: [],
        workspaces: [],
    };

    var root;
    try {
        root = JSON.parse(text);
    } catch (parseError) {
        errors.push(makeDiagnostic("manifest-invalid-json", "manifest",
            "Manifest is not valid JSON: " + String(parseError.message || parseError)));
        return result;
    }
    if (!isPlainObject(root)) {
        errors.push(makeDiagnostic("manifest-not-object", "manifest",
            "Manifest root must be a JSON object."));
        return result;
    }

    var rootKeys = Object.keys(root);
    for (var k = 0; k < rootKeys.length; k += 1) {
        if (!contains(ROOT_FIELDS, rootKeys[k])) {
            errors.push(makeDiagnostic("root-unknown-field", rootKeys[k],
                "Unknown root field \"" + rootKeys[k]
                + "\" is not part of the v1 contract."));
        }
    }
    if (root.localwrap !== 1) {
        errors.push(makeDiagnostic("manifest-version", "localwrap",
            "Version 1 requires \"localwrap\": 1."));
    }
    if (root.name !== undefined) {
        if (!isNonEmptyString(root.name)) {
            errors.push(makeDiagnostic("name-invalid", "name",
                "Workspace name must be a non-empty string."));
        } else {
            result.name = root.name.trim();
        }
    }
    if (!Array.isArray(root.projects) || root.projects.length === 0) {
        errors.push(makeDiagnostic("projects-required", "projects",
            "Manifest requires at least one project."));
        return result;
    }

    var usedProjectIDs = {};
    var projects = [];
    for (var index = 0; index < root.projects.length; index += 1) {
        var scope = "projects[" + index + "]";
        var raw = root.projects[index];
        if (!isPlainObject(raw)) {
            errors.push(makeDiagnostic("project-not-object", scope,
                "Project entry must be a JSON object."));
            continue;
        }
        var projectKeys = Object.keys(raw);
        for (var p = 0; p < projectKeys.length; p += 1) {
            if (!contains(PROJECT_FIELDS, projectKeys[p])) {
                errors.push(makeDiagnostic("project-unknown-field",
                    scope + "." + projectKeys[p],
                    "Unknown project field \"" + projectKeys[p]
                    + "\" is not part of the v1 contract."));
            }
        }

        var project = {
            id: null,
            name: null,
            path: ".",
            command: null,
            commandLine: "",
            port: DEFAULT_PORT,
            url: null,
            autostart: false,
            openOnReady: true,
            dependsOn: [],
            dependsOnRaw: [],
            healthCheckURL: null,
        };

        if (raw.id !== undefined) {
            if (!isNonEmptyString(raw.id) || raw.id.length > 128) {
                errors.push(makeDiagnostic("id-invalid", scope + ".id",
                    "Project id must be a non-empty string of at most 128 characters."));
            } else {
                project.id = raw.id.trim();
            }
        }
        if (raw.name !== undefined) {
            if (!isNonEmptyString(raw.name)) {
                errors.push(makeDiagnostic("name-invalid", scope + ".name",
                    "Project name must be a non-empty string."));
            } else {
                project.name = raw.name.trim();
            }
        }

        if (!isNonEmptyString(raw.command)) {
            errors.push(makeDiagnostic("command-required", scope + ".command",
                "Project command is required."));
        } else {
            var parsedCommand = parseCommand(raw.command);
            if (!parsedCommand.ok) {
                errors.push(makeDiagnostic("command-invalid", scope + ".command",
                    parsedCommand.error));
            } else {
                project.command = parsedCommand;
                project.commandLine = formatCommand(parsedCommand);
            }
        }

        if (raw.path !== undefined) {
            var validatedPath = validateRelativePath(raw.path);
            if (!validatedPath.ok) {
                errors.push(makeDiagnostic("path-invalid", scope + ".path",
                    validatedPath.error));
            } else {
                project.path = validatedPath.path;
            }
        }

        if (raw.port !== undefined) {
            if (typeof raw.port !== "number" || raw.port % 1 !== 0
                || raw.port < MIN_PORT || raw.port > MAX_PORT) {
                errors.push(makeDiagnostic("port-invalid", scope + ".port",
                    "Port must be an integer between " + MIN_PORT + " and "
                    + MAX_PORT + "."));
            } else {
                project.port = raw.port;
            }
        }

        if (raw.url !== undefined) {
            if (!isString(raw.url)) {
                errors.push(makeDiagnostic("url-invalid", scope + ".url",
                    "URL must be a string."));
            } else {
                var validatedURL = validateLoopbackURL(raw.url);
                if (!validatedURL.ok) {
                    errors.push(makeDiagnostic("url-invalid", scope + ".url",
                        validatedURL.error));
                } else {
                    project.url = validatedURL.href;
                    if (raw.port !== undefined && validatedURL.port !== project.port) {
                        warnings.push(makeDiagnostic("url-port-mismatch", scope + ".url",
                            "URL port " + validatedURL.port
                            + " differs from the configured port " + project.port + "."));
                    }
                }
            }
        }
        if (project.url === null) {
            project.url = "http://localhost:" + project.port;
        }

        if (raw.autostart !== undefined) {
            if (!isBoolean(raw.autostart)) {
                errors.push(makeDiagnostic("autostart-invalid", scope + ".autostart",
                    "autostart must be a boolean."));
            } else {
                project.autostart = raw.autostart;
            }
        }
        if (raw.openOnReady !== undefined) {
            if (!isBoolean(raw.openOnReady)) {
                errors.push(makeDiagnostic("open-on-ready-invalid", scope + ".openOnReady",
                    "openOnReady must be a boolean."));
            } else {
                project.openOnReady = raw.openOnReady;
            }
        }

        if (raw.dependsOn !== undefined) {
            if (!Array.isArray(raw.dependsOn)) {
                errors.push(makeDiagnostic("depends-on-invalid", scope + ".dependsOn",
                    "dependsOn must be an array of project IDs."));
            } else {
                var seenRefs = {};
                for (var d = 0; d < raw.dependsOn.length; d += 1) {
                    var ref = raw.dependsOn[d];
                    if (!isNonEmptyString(ref)) {
                        errors.push(makeDiagnostic("depends-on-invalid",
                            scope + ".dependsOn[" + d + "]",
                            "Dependency references must be non-empty strings."));
                        continue;
                    }
                    if (seenRefs[ref] === true) {
                        errors.push(makeDiagnostic("depends-on-duplicate",
                            scope + ".dependsOn[" + d + "]",
                            "Dependency \"" + ref + "\" is listed more than once."));
                        continue;
                    }
                    seenRefs[ref] = true;
                    project.dependsOnRaw.push(ref.trim());
                }
            }
        }

        if (raw.healthCheck !== undefined) {
            if (!isPlainObject(raw.healthCheck)) {
                errors.push(makeDiagnostic("health-check-invalid", scope + ".healthCheck",
                    "healthCheck must be an object with either a path or a URL."));
            } else {
                var healthKeys = Object.keys(raw.healthCheck);
                var healthShapeOK = true;
                for (var h = 0; h < healthKeys.length; h += 1) {
                    if (!contains(HEALTH_CHECK_FIELDS, healthKeys[h])) {
                        errors.push(makeDiagnostic("health-check-unknown-field",
                            scope + ".healthCheck." + healthKeys[h],
                            "Unknown health check field \"" + healthKeys[h] + "\"."));
                        healthShapeOK = false;
                    }
                }
                if (healthShapeOK) {
                    var resolution = resolveHealthCheck(project.url, raw.healthCheck);
                    if (!resolution.ok) {
                        errors.push(makeDiagnostic("health-check-invalid",
                            scope + ".healthCheck", resolution.error));
                    } else {
                        project.healthCheckURL = resolution.url;
                    }
                }
            }
        }
        if (project.healthCheckURL === null) {
            var defaultResolution = resolveHealthCheck(project.url, null);
            if (defaultResolution.ok) {
                project.healthCheckURL = defaultResolution.url;
            }
        }

        projects.push(project);
    }

    // Assign stable lowercase slug IDs, exactly like review: explicit id
    // first, then name, then position.
    for (var n = 0; n < projects.length; n += 1) {
        var source = projects[n].id !== null ? projects[n].id
            : (projects[n].name !== null ? projects[n].name : "project-" + (n + 1));
        var assigned = uniqueSlug(source, usedProjectIDs);
        if (projects[n].name === null) {
            projects[n].name = projects[n].id !== null ? projects[n].id : assigned;
        }
        projects[n].id = assigned;
    }

    // Resolve dependency references against assigned IDs.
    var idIndex = {};
    for (var m = 0; m < projects.length; m += 1) {
        idIndex[projects[m].id] = m;
    }
    for (var q = 0; q < projects.length; q += 1) {
        var owner = projects[q];
        for (var r = 0; r < owner.dependsOnRaw.length; r += 1) {
            var refSlug = slugify(owner.dependsOnRaw[r]);
            if (idIndex[refSlug] === undefined) {
                errors.push(makeDiagnostic("dependency-unknown",
                    "projects[" + q + "].dependsOn",
                    "Dependency \"" + owner.dependsOnRaw[r]
                    + "\" does not match any project ID."));
            } else if (refSlug === owner.id) {
                errors.push(makeDiagnostic("dependency-self",
                    "projects[" + q + "].dependsOn",
                    "Project \"" + owner.id + "\" cannot depend on itself."));
            } else {
                owner.dependsOn.push(refSlug);
            }
        }
        delete owner.dependsOnRaw;
    }

    // Reject dependency cycles so start gating can always terminate.
    var cycleMember = findDependencyCycleMember(projects);
    if (cycleMember !== null) {
        errors.push(makeDiagnostic("dependency-cycle", "projects",
            "Dependency cycle detected involving \"" + cycleMember + "\"."));
    }

    var workspaces = [];
    if (root.workspaces !== undefined) {
        if (!Array.isArray(root.workspaces)) {
            errors.push(makeDiagnostic("workspaces-invalid", "workspaces",
                "workspaces must be an array."));
        } else {
            var usedWorkspaceIDs = {};
            for (var w = 0; w < root.workspaces.length; w += 1) {
                var wScope = "workspaces[" + w + "]";
                var rawWorkspace = root.workspaces[w];
                if (!isPlainObject(rawWorkspace)) {
                    errors.push(makeDiagnostic("workspace-not-object", wScope,
                        "Workspace entry must be a JSON object."));
                    continue;
                }
                var workspaceKeys = Object.keys(rawWorkspace);
                for (var wk = 0; wk < workspaceKeys.length; wk += 1) {
                    if (!contains(WORKSPACE_FIELDS, workspaceKeys[wk])) {
                        errors.push(makeDiagnostic("workspace-unknown-field",
                            wScope + "." + workspaceKeys[wk],
                            "Unknown workspace field \"" + workspaceKeys[wk]
                            + "\" is not part of the v1 contract."));
                    }
                }
                var workspace = { id: null, name: null, projects: [] };
                if (rawWorkspace.id !== undefined) {
                    if (!isNonEmptyString(rawWorkspace.id) || rawWorkspace.id.length > 128) {
                        errors.push(makeDiagnostic("id-invalid", wScope + ".id",
                            "Workspace id must be a non-empty string of at most 128 characters."));
                    } else {
                        workspace.id = rawWorkspace.id.trim();
                    }
                }
                if (rawWorkspace.name !== undefined) {
                    if (!isNonEmptyString(rawWorkspace.name)) {
                        errors.push(makeDiagnostic("name-invalid", wScope + ".name",
                            "Workspace name must be a non-empty string."));
                    } else {
                        workspace.name = rawWorkspace.name.trim();
                    }
                }
                if (!Array.isArray(rawWorkspace.projects) || rawWorkspace.projects.length === 0) {
                    errors.push(makeDiagnostic("workspace-projects-required",
                        wScope + ".projects",
                        "A workspace must reference at least one manifest project."));
                } else {
                    var seenMembers = {};
                    for (var wm = 0; wm < rawWorkspace.projects.length; wm += 1) {
                        var member = rawWorkspace.projects[wm];
                        if (!isNonEmptyString(member)) {
                            errors.push(makeDiagnostic("workspace-reference-invalid",
                                wScope + ".projects[" + wm + "]",
                                "Workspace references must be non-empty strings."));
                            continue;
                        }
                        var memberSlug = slugify(member);
                        if (seenMembers[memberSlug] === true) {
                            errors.push(makeDiagnostic("workspace-reference-duplicate",
                                wScope + ".projects[" + wm + "]",
                                "Workspace lists project \"" + member + "\" more than once."));
                            continue;
                        }
                        seenMembers[memberSlug] = true;
                        if (idIndex[memberSlug] === undefined) {
                            errors.push(makeDiagnostic("workspace-reference-unknown",
                                wScope + ".projects[" + wm + "]",
                                "Workspace references unknown project \"" + member + "\"."));
                        } else {
                            workspace.projects.push(memberSlug);
                        }
                    }
                }
                var workspaceSource = workspace.id !== null ? workspace.id
                    : (workspace.name !== null ? workspace.name : "workspace-" + (w + 1));
                var workspaceID = uniqueSlug(workspaceSource, usedWorkspaceIDs);
                if (workspace.name === null) {
                    workspace.name = workspace.id !== null ? workspace.id : workspaceID;
                }
                workspace.id = workspaceID;
                workspaces.push(workspace);
            }
        }
    }

    result.projects = projects;
    result.workspaces = workspaces;
    result.ok = errors.length === 0;
    return result;
}

function findDependencyCycleMember(projects) {
    var edges = {};
    var i;
    for (i = 0; i < projects.length; i += 1) {
        edges[projects[i].id] = projects[i].dependsOn || [];
    }
    var visiting = {};
    var done = {};

    function visit(id) {
        if (done[id] === true) { return null; }
        if (visiting[id] === true) { return id; }
        visiting[id] = true;
        var deps = edges[id] || [];
        for (var e = 0; e < deps.length; e += 1) {
            var found = visit(deps[e]);
            if (found !== null) { return found; }
        }
        visiting[id] = false;
        done[id] = true;
        return null;
    }

    for (i = 0; i < projects.length; i += 1) {
        var member = visit(projects[i].id);
        if (member !== null) { return member; }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Plugin repositories configuration
// ---------------------------------------------------------------------------

// The plugin's own configuration is one explicit, user-owned file:
//   ~/.config/localwrap/repositories.json
//   {
//     "repositories": ["/absolute/path/to/repo", "~/relative/to/home"],
//     "notifications": false,
//     "openOnReady": false
//   }
// Listing a repository only allows its manifest to be read and reviewed;
// nothing is ever started from configuration alone. Both optional flags
// default to off: notifications sends desktop notifications on runtime
// transitions, and openOnReady allows opening a project's URL when it
// becomes ready (only for projects whose manifest also opts in).
function parseRepositoriesConfig(text, homeDirectory) {
    var errors = [];
    var repositories = [];
    var result = {
        ok: false, errors: errors, repositories: repositories,
        notifications: false, openOnReady: false,
    };

    var root;
    try {
        root = JSON.parse(text);
    } catch (parseError) {
        errors.push(makeDiagnostic("config-invalid-json", "config",
            "Configuration is not valid JSON: " + String(parseError.message || parseError)));
        return result;
    }
    if (!isPlainObject(root)) {
        errors.push(makeDiagnostic("config-not-object", "config",
            "Configuration root must be a JSON object."));
        return result;
    }
    var keys = Object.keys(root);
    for (var k = 0; k < keys.length; k += 1) {
        if (!contains(["repositories", "notifications", "openOnReady"], keys[k])) {
            errors.push(makeDiagnostic("config-unknown-field", keys[k],
                "Unknown configuration field \"" + keys[k] + "\"."));
        }
    }
    if (root.notifications !== undefined) {
        if (!isBoolean(root.notifications)) {
            errors.push(makeDiagnostic("config-notifications-invalid", "notifications",
                "notifications must be a boolean."));
        } else {
            result.notifications = root.notifications;
        }
    }
    if (root.openOnReady !== undefined) {
        if (!isBoolean(root.openOnReady)) {
            errors.push(makeDiagnostic("config-open-on-ready-invalid", "openOnReady",
                "openOnReady must be a boolean."));
        } else {
            result.openOnReady = root.openOnReady;
        }
    }
    if (!Array.isArray(root.repositories)) {
        errors.push(makeDiagnostic("config-repositories-required", "repositories",
            "Configuration requires a \"repositories\" array."));
        return result;
    }
    var seen = {};
    for (var i = 0; i < root.repositories.length; i += 1) {
        var scope = "repositories[" + i + "]";
        var entry = root.repositories[i];
        if (!isNonEmptyString(entry)) {
            errors.push(makeDiagnostic("config-repository-invalid", scope,
                "Repository entries must be non-empty strings."));
            continue;
        }
        var path = entry.trim().replace(/\/+$/, "");
        if (path === "~" || path.slice(0, 2) === "~/") {
            if (!isNonEmptyString(homeDirectory)) {
                errors.push(makeDiagnostic("config-repository-invalid", scope,
                    "Cannot expand \"~\" without a home directory."));
                continue;
            }
            path = homeDirectory.replace(/\/+$/, "") + path.slice(1);
        }
        if (path.charAt(0) !== "/") {
            errors.push(makeDiagnostic("config-repository-invalid", scope,
                "Repository paths must be absolute (or start with ~/)."));
            continue;
        }
        if (seen[path] === true) {
            errors.push(makeDiagnostic("config-repository-duplicate", scope,
                "Repository \"" + path + "\" is listed more than once."));
            continue;
        }
        seen[path] = true;
        repositories.push(path);
    }
    result.ok = errors.length === 0;
    return result;
}

function manifestCandidatePaths(repositoryRoot) {
    var paths = [];
    for (var i = 0; i < MANIFEST_RELATIVE_PATHS.length; i += 1) {
        paths.push(joinPath(repositoryRoot, MANIFEST_RELATIVE_PATHS[i]));
    }
    return paths;
}

// ---------------------------------------------------------------------------
// Runtime status model
// ---------------------------------------------------------------------------

function statusLabel(status) {
    switch (status) {
    case STATUS.stopped: return "Stopped";
    case STATUS.starting: return "Starting";
    case STATUS.ready: return "Ready";
    case STATUS.stalled: return "Running, not ready";
    case STATUS.stopping: return "Stopping";
    case STATUS.failed: return "Failed";
    case STATUS.conflict: return "Port already in use";
    default: return "Unknown";
    }
}

function statusColor(status) {
    switch (status) {
    case STATUS.ready: return "#4ade80";
    case STATUS.starting: return "#facc15";
    case STATUS.stopping: return "#facc15";
    case STATUS.stalled: return "#fb923c";
    case STATUS.failed: return "#f87171";
    case STATUS.conflict: return "#f87171";
    default: return "#6b7280";
    }
}

function isRunningStatus(status) {
    return status === STATUS.starting || status === STATUS.ready
        || status === STATUS.stalled || status === STATUS.stopping;
}

// statuses: array of STATUS strings for every configured project.
function summarizeStatuses(statuses) {
    var summary = { total: statuses.length, running: 0, ready: 0, attention: 0 };
    for (var i = 0; i < statuses.length; i += 1) {
        if (isRunningStatus(statuses[i])) { summary.running += 1; }
        if (statuses[i] === STATUS.ready) { summary.ready += 1; }
        if (statuses[i] === STATUS.failed || statuses[i] === STATUS.conflict) {
            summary.attention += 1;
        }
    }
    return summary;
}

function barLabel(summary) {
    if (summary === null || summary === undefined || summary.total === 0) {
        return "LW";
    }
    var label = "LW " + summary.ready + "/" + summary.total;
    return summary.attention > 0 ? label + "!" : label;
}

function barTooltip(summary) {
    if (summary === null || summary === undefined || summary.total === 0) {
        return "LocalWrap: no projects configured";
    }
    var parts = ["LocalWrap: " + summary.ready + " of " + summary.total + " ready"];
    if (summary.running > summary.ready) {
        parts.push((summary.running - summary.ready) + " starting");
    }
    if (summary.attention > 0) {
        parts.push(summary.attention + " need attention");
    }
    return parts.join(", ");
}

// Start gating: every dependency must be Ready before a project may start.
// statusesByID: { projectID: STATUS }.
function canStart(project, statusesByID) {
    var status = statusesByID[project.id];
    if (isRunningStatus(status)) {
        return { ok: false, reason: "Project is already running." };
    }
    var missing = [];
    for (var i = 0; i < project.dependsOn.length; i += 1) {
        if (statusesByID[project.dependsOn[i]] !== STATUS.ready) {
            missing.push(project.dependsOn[i]);
        }
    }
    if (missing.length > 0) {
        return {
            ok: false,
            reason: "Waiting on " + missing.join(", ") + " to become ready.",
        };
    }
    return { ok: true, reason: "" };
}

// ---------------------------------------------------------------------------
// Process and probe plumbing shared with the QML layer
// ---------------------------------------------------------------------------

// Readiness probes mirror the app: HEAD request, 1 second budget, any HTTP
// status below 500 counts as ready (a 404 still proves the port answered).
function curlProbeArgv(url) {
    return [
        "curl", "-s", "-o", "/dev/null", "-I",
        "-w", "%{http_code}",
        "--max-time", String(PROBE_TIMEOUT_SECONDS),
        url,
    ];
}

function isReadyHttpCode(codeText) {
    var code = parseInt(String(codeText).trim(), 10);
    if (isNaN(code)) { return false; }
    return code >= 100 && code < 500;
}

// Bounded, in-memory output tail for failure context. Mirrors the app's
// privacy rule: shown live in the panel, never written to disk.
function appendOutputTail(existing, chunk, maxLines) {
    var lines = existing.concat(String(chunk).split(/\r?\n/));
    var kept = [];
    for (var i = 0; i < lines.length; i += 1) {
        if (lines[i] !== "") { kept.push(lines[i]); }
    }
    if (kept.length > maxLines) {
        kept = kept.slice(kept.length - maxLines);
    }
    return kept;
}

// ---------------------------------------------------------------------------
// Workspace orchestration (dependency-ordered start)
// ---------------------------------------------------------------------------

// The start plan for a workspace is its members plus every transitive
// dependency, ordered so dependencies come before dependents. Ties follow
// manifest order, keeping plans deterministic. Cycles cannot reach here:
// parsing rejects them as blockers.
function workspaceStartPlan(projects, workspace) {
    var byID = {};
    var i;
    for (i = 0; i < projects.length; i += 1) {
        byID[projects[i].id] = projects[i];
    }
    var include = {};
    function add(id) {
        if (include[id] === true || byID[id] === undefined) { return; }
        include[id] = true;
        var deps = byID[id].dependsOn || [];
        for (var d = 0; d < deps.length; d += 1) { add(deps[d]); }
    }
    for (i = 0; i < workspace.projects.length; i += 1) {
        add(workspace.projects[i]);
    }

    var plan = [];
    var placed = {};
    var remaining = 0;
    for (i = 0; i < projects.length; i += 1) {
        if (include[projects[i].id] === true) { remaining += 1; }
    }
    while (remaining > 0) {
        var progressed = false;
        for (i = 0; i < projects.length; i += 1) {
            var candidate = projects[i];
            if (include[candidate.id] !== true || placed[candidate.id] === true) {
                continue;
            }
            var deps = candidate.dependsOn || [];
            var waitingOnDep = false;
            for (var d2 = 0; d2 < deps.length; d2 += 1) {
                if (include[deps[d2]] === true && placed[deps[d2]] !== true) {
                    waitingOnDep = true;
                    break;
                }
            }
            if (waitingOnDep) { continue; }
            placed[candidate.id] = true;
            plan.push(candidate.id);
            remaining -= 1;
            progressed = true;
        }
        if (!progressed) { break; }
    }
    return plan;
}

// Stop dependents before their dependencies: the reverse of the start plan,
// filtered to members that are actually running.
function workspaceStopPlan(plan, statusesByID) {
    var stops = [];
    for (var i = plan.length - 1; i >= 0; i -= 1) {
        if (isRunningStatus(statusesByID[plan[i]])) { stops.push(plan[i]); }
    }
    return stops;
}

// One orchestration decision. Returns which plan members may start right
// now (stopped with every dependency ready), which are still waiting, the
// first member that halted the run (failed, conflict, or stalled), and
// whether the whole plan is ready.
function orchestrationStep(plan, projectsByID, statusesByID) {
    var startNow = [];
    var waiting = [];
    var blocked = null;
    var readyCount = 0;
    for (var i = 0; i < plan.length; i += 1) {
        var id = plan[i];
        var status = statusesByID[id] === undefined ? STATUS.stopped : statusesByID[id];
        if (status === STATUS.ready) {
            readyCount += 1;
            continue;
        }
        if (status === STATUS.failed || status === STATUS.conflict
            || status === STATUS.stalled) {
            if (blocked === null) { blocked = { id: id, status: status }; }
            continue;
        }
        if (status === STATUS.starting || status === STATUS.stopping) {
            waiting.push(id);
            continue;
        }
        var project = projectsByID[id];
        var deps = project ? (project.dependsOn || []) : [];
        var depsReady = true;
        for (var d = 0; d < deps.length; d += 1) {
            if (statusesByID[deps[d]] !== STATUS.ready) {
                depsReady = false;
                break;
            }
        }
        if (depsReady) { startNow.push(id); } else { waiting.push(id); }
    }
    return {
        startNow: startNow,
        waiting: waiting,
        blocked: blocked,
        readyCount: readyCount,
        total: plan.length,
        done: blocked === null && readyCount === plan.length,
    };
}

// ---------------------------------------------------------------------------
// Manifest change watching (mtime polling)
// ---------------------------------------------------------------------------

var WATCH_POLL_INTERVAL_MS = 5000;

// Watch the configuration file plus both manifest candidates for every
// repository, so newly created manifests are noticed too.
function watchPathsFor(configPath, repositoryRoots) {
    var paths = [configPath];
    for (var i = 0; i < repositoryRoots.length; i += 1) {
        var candidates = manifestCandidatePaths(repositoryRoots[i]);
        for (var j = 0; j < candidates.length; j += 1) {
            paths.push(candidates[j]);
        }
    }
    return paths;
}

function statWatchArgv(paths) {
    return ["stat", "-c", "%n %Y"].concat(paths);
}

// stat prints "<path> <mtime>" per existing file; missing files only add
// stderr noise. Paths may contain spaces, so split on the last space and
// require the trailing token to be a pure integer timestamp.
function parseStatTimes(text) {
    var times = {};
    var lines = String(text).split("\n");
    for (var i = 0; i < lines.length; i += 1) {
        var cut = lines[i].lastIndexOf(" ");
        if (cut <= 0) { continue; }
        var mtime = lines[i].slice(cut + 1);
        if (!/^\d+$/.test(mtime)) { continue; }
        times[lines[i].slice(0, cut)] = mtime;
    }
    return times;
}

function sameStatTimes(a, b) {
    var aKeys = Object.keys(a);
    var bKeys = Object.keys(b);
    if (aKeys.length !== bKeys.length) { return false; }
    for (var i = 0; i < aKeys.length; i += 1) {
        if (b[aKeys[i]] !== a[aKeys[i]]) { return false; }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Desktop notifications (opt-in, transition-only)
// ---------------------------------------------------------------------------

// Mirrors the app's opt-in runtime notifications: deduplicated status
// transitions only, never command output. Returns null for statuses that
// are not notable.
function notificationForTransition(name, status, detail) {
    switch (status) {
    case STATUS.ready:
        return { summary: name + " is ready", body: detail || "" };
    case STATUS.failed:
        return { summary: name + " failed", body: detail || "" };
    case STATUS.conflict:
        return { summary: name + ": port already in use", body: detail || "" };
    case STATUS.stalled:
        return { summary: name + " is running but not ready", body: detail || "" };
    default:
        return null;
    }
}

function notifySendArgv(summary, body) {
    var argv = ["notify-send", "-a", "LocalWrap", summary];
    if (isNonEmptyString(body)) { argv.push(body); }
    return argv;
}

// Pre-start check that the project directory exists, mirroring the app's
// cwd-missing Doctor finding.
function dirCheckArgv(path) {
    return ["test", "-d", path];
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        ALLOWED_EXECUTABLES: ALLOWED_EXECUTABLES,
        ALLOWED_URL_HOSTS: ALLOWED_URL_HOSTS,
        MIN_PORT: MIN_PORT,
        MAX_PORT: MAX_PORT,
        DEFAULT_PORT: DEFAULT_PORT,
        READY_POLL_INTERVAL_MS: READY_POLL_INTERVAL_MS,
        READY_TIMEOUT_MS: READY_TIMEOUT_MS,
        PROBE_TIMEOUT_SECONDS: PROBE_TIMEOUT_SECONDS,
        MANIFEST_RELATIVE_PATHS: MANIFEST_RELATIVE_PATHS,
        STATUS: STATUS,
        basename: basename,
        parseCommand: parseCommand,
        formatCommand: formatCommand,
        validateLoopbackURL: validateLoopbackURL,
        resolveHealthCheck: resolveHealthCheck,
        slugify: slugify,
        uniqueSlug: uniqueSlug,
        validateRelativePath: validateRelativePath,
        joinPath: joinPath,
        parseWorkspaceManifest: parseWorkspaceManifest,
        parseRepositoriesConfig: parseRepositoriesConfig,
        manifestCandidatePaths: manifestCandidatePaths,
        statusLabel: statusLabel,
        statusColor: statusColor,
        isRunningStatus: isRunningStatus,
        summarizeStatuses: summarizeStatuses,
        barLabel: barLabel,
        barTooltip: barTooltip,
        canStart: canStart,
        curlProbeArgv: curlProbeArgv,
        isReadyHttpCode: isReadyHttpCode,
        appendOutputTail: appendOutputTail,
        WATCH_POLL_INTERVAL_MS: WATCH_POLL_INTERVAL_MS,
        workspaceStartPlan: workspaceStartPlan,
        workspaceStopPlan: workspaceStopPlan,
        orchestrationStep: orchestrationStep,
        watchPathsFor: watchPathsFor,
        statWatchArgv: statWatchArgv,
        parseStatTimes: parseStatTimes,
        sameStatTimes: sameStatTimes,
        notificationForTransition: notificationForTransition,
        notifySendArgv: notifySendArgv,
        dirCheckArgv: dirCheckArgv,
    };
}
