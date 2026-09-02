// Node test suite for Model.js — run with: node --test omarchy-plugin/tests
//
// Model.js is the exact file the QML entry points import, so these tests
// exercise the same code paths the Omarchy shell runs. Expected behavior is
// pinned to the LocalWrap workspace-manifest v1 contract
// (Documentation/workspace-manifest-v1.md) and the Swift services it ports.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const Model = require(path.join(__dirname, "..", "Model.js"));

const DOCS_EXAMPLE = JSON.stringify({
    localwrap: 1,
    name: "Storefront",
    projects: [
        {
            autostart: false,
            command: "pnpm run dev",
            dependsOn: ["api"],
            healthCheck: { path: "/health" },
            id: "web",
            name: "Web",
            openOnReady: true,
            path: "apps/web",
            port: 3000,
            url: "http://127.0.0.1:3000",
        },
        {
            command: "npm run dev",
            id: "api",
            name: "API",
            path: "apps/api",
            port: 3001,
            url: "http://127.0.0.1:3001",
        },
    ],
    workspaces: [
        { id: "full-stack", name: "Full stack", projects: ["api", "web"] },
    ],
});

function codes(result) {
    return result.errors.map((diagnostic) => diagnostic.code).sort();
}

test("parseCommand accepts an exact local package script", () => {
    const parsed = Model.parseCommand("  pnpm  run dev  ");
    assert.equal(parsed.ok, true);
    assert.equal(parsed.executable, "pnpm");
    assert.deepEqual(parsed.arguments, ["run", "dev"]);
    assert.equal(Model.formatCommand(parsed), "pnpm run dev");
});

test("parseCommand rejects executables outside the allowlist", () => {
    for (const command of ["bash run.sh", "rm -rf x", "./node_modules/.bin/vite", "curl http://localhost:3000"]) {
        const parsed = Model.parseCommand(command);
        assert.equal(parsed.ok, false, command);
        assert.match(parsed.error, /not allowed/);
    }
});

test("parseCommand rejects every documented shell metacharacter", () => {
    const rejected = [
        "npm run dev; ls", "npm run dev && ls", "npm run dev | tee log",
        "npm run dev $PORT", "npm run `id`", "npm run dev > out",
        "npm run dev < in", "npm run (dev)", "npm run {dev}", "npm run [dev]",
        "npm run dev!", "npm run dev #x", "npm run *", "npm run dev?",
        "npm run ~x", "npm run 100%", "npm run ^dev", "npm run \"dev\"",
        "npm run 'dev'", "npm run dev\nls",
    ];
    for (const command of rejected) {
        const parsed = Model.parseCommand(command);
        assert.equal(parsed.ok, false, JSON.stringify(command));
        assert.match(parsed.error, /disallowed characters/);
    }
    assert.equal(Model.parseCommand("").ok, false);
    assert.equal(Model.parseCommand("   ").ok, false);
});

test("validateLoopbackURL accepts numeric loopback hosts with explicit ports", () => {
    for (const url of [
        "http://127.0.0.1:3000",
        "https://127.0.0.1:8443/path?q=1#frag",
        "http://[::1]:4000/health",
    ]) {
        const validated = Model.validateLoopbackURL(url);
        assert.equal(validated.ok, true, url);
    }
    const parsed = Model.validateLoopbackURL("https://127.0.0.1:8443/path?q=1#frag");
    assert.equal(parsed.scheme, "https");
    assert.equal(parsed.host, "127.0.0.1");
    assert.equal(parsed.port, 8443);
    assert.equal(parsed.origin, "https://127.0.0.1:8443");
    assert.equal(parsed.href, "https://127.0.0.1:8443/path?q=1#frag");
});

test("validateLoopbackURL rejects everything outside the loopback contract", () => {
    const rejected = [
        "http://localhost",            // no port
        "http://localhost:3000",       // hostname is not a network boundary
        "http://localhost:999",        // port below 1000
        "http://localhost:70000",      // port above 65535
        "http://example.com:3000",     // non-loopback host
        "http://0.0.0.0:3000",         // wildcard host
        "http://192.168.1.10:3000",    // LAN host
        "ftp://localhost:3000",        // scheme
        "http://user@localhost:3000",  // userinfo
        "http://user:pw@localhost:3000",
        "http://::1:3000",             // IPv6 without brackets
        "localhost:3000",              // no scheme
        "",
    ];
    for (const url of rejected) {
        assert.equal(Model.validateLoopbackURL(url).ok, false, url);
    }
});

test("resolveHealthCheck follows path/url exclusivity and strips query and fragment", () => {
    const fromPath = Model.resolveHealthCheck("http://127.0.0.1:3000/app?x=1#y", { path: "/health" });
    assert.deepEqual(fromPath, { ok: true, url: "http://127.0.0.1:3000/health" });

    const fromURL = Model.resolveHealthCheck("http://127.0.0.1:3000", { url: "http://127.0.0.1:3100/ping" });
    assert.deepEqual(fromURL, { ok: true, url: "http://127.0.0.1:3100/ping" });

    const fallback = Model.resolveHealthCheck("http://127.0.0.1:3000/app", null);
    assert.deepEqual(fallback, { ok: true, url: "http://127.0.0.1:3000/app" });

    assert.equal(Model.resolveHealthCheck("http://localhost:3000", { path: "/a", url: "http://localhost:3000/b" }).ok, false);
    assert.equal(Model.resolveHealthCheck("http://localhost:3000", {}).ok, false);
    assert.equal(Model.resolveHealthCheck("http://localhost:3000", { path: "health" }).ok, false);
    assert.equal(Model.resolveHealthCheck("http://localhost:3000", { url: "http://evil.example:3000" }).ok, false);
    assert.equal(Model.resolveHealthCheck("http://example.com:3000", { path: "/health" }).ok, false);
});

test("slugify and uniqueSlug mirror review's identifier normalisation", () => {
    assert.equal(Model.slugify("My API"), "my-api");
    assert.equal(Model.slugify("  Weird__Name!!  "), "weird-name");
    assert.equal(Model.slugify("Web App 2"), "web-app-2");
    assert.equal(Model.slugify("???"), "item");

    const used = {};
    assert.equal(Model.uniqueSlug("Web", used), "web");
    assert.equal(Model.uniqueSlug("web", used), "web-2");
    assert.equal(Model.uniqueSlug("WEB", used), "web-3");
});

test("validateRelativePath enforces containment lexically", () => {
    assert.equal(Model.validateRelativePath("apps/web").ok, true);
    assert.equal(Model.validateRelativePath(".").ok, true);
    assert.equal(Model.validateRelativePath("a/../b").ok, true);
    assert.equal(Model.validateRelativePath("/abs/path").ok, false);
    assert.equal(Model.validateRelativePath("..").ok, false);
    assert.equal(Model.validateRelativePath("a/../../b").ok, false);
});

test("parseWorkspaceManifest accepts the documentation example verbatim", () => {
    const result = Model.parseWorkspaceManifest(DOCS_EXAMPLE, "storefront");
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.warnings, []);
    assert.equal(result.ok, true);
    assert.equal(result.name, "Storefront");

    assert.equal(result.projects.length, 2);
    const [web, api] = result.projects;

    assert.equal(web.id, "web");
    assert.equal(web.name, "Web");
    assert.equal(web.path, "apps/web");
    assert.equal(web.commandLine, "pnpm run dev");
    assert.equal(web.port, 3000);
    assert.equal(web.url, "http://127.0.0.1:3000");
    assert.deepEqual(web.dependsOn, ["api"]);
    assert.equal(web.healthCheckURL, "http://127.0.0.1:3000/health");
    assert.equal(web.autostart, false);
    assert.equal(web.openOnReady, true);

    assert.equal(api.id, "api");
    assert.equal(api.port, 3001);
    assert.equal(api.url, "http://127.0.0.1:3001");
    assert.equal(api.healthCheckURL, "http://127.0.0.1:3001");
    assert.deepEqual(api.dependsOn, []);

    assert.equal(result.workspaces.length, 1);
    assert.equal(result.workspaces[0].id, "full-stack");
    assert.deepEqual(result.workspaces[0].projects, ["api", "web"]);
});

test("parseWorkspaceManifest applies the documented defaults", () => {
    const result = Model.parseWorkspaceManifest(
        JSON.stringify({ localwrap: 1, projects: [{ command: "npm run dev" }] }),
        "my-repo");
    assert.equal(result.ok, true);
    assert.equal(result.name, "my-repo");
    const project = result.projects[0];
    assert.equal(project.id, "project-1");
    assert.equal(project.name, "project-1");
    assert.equal(project.path, ".");
    assert.equal(project.port, 3000);
    assert.equal(project.url, "http://127.0.0.1:3000");
    assert.equal(project.healthCheckURL, "http://127.0.0.1:3000");
    assert.equal(project.autostart, false);
    assert.equal(project.openOnReady, true);
});

test("parseWorkspaceManifest rejects unknown and secret-bearing fields", () => {
    const badRoot = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        environment: { API_KEY: "x" },
        projects: [{ command: "npm run dev" }],
    }), "repo");
    assert.equal(badRoot.ok, false);
    assert.ok(codes(badRoot).includes("root-unknown-field"));

    const badProject = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ command: "npm run dev", env: { SECRET: "x" } }],
    }), "repo");
    assert.equal(badProject.ok, false);
    assert.ok(codes(badProject).includes("project-unknown-field"));
});

test("parseWorkspaceManifest requires version 1 and at least one project", () => {
    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({ projects: [{ command: "npm start" }] }), "r"))
        .includes("manifest-version"));
    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({ localwrap: 2, projects: [{ command: "npm start" }] }), "r"))
        .includes("manifest-version"));
    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({ localwrap: 1, projects: [] }), "r"))
        .includes("projects-required"));
    assert.ok(codes(Model.parseWorkspaceManifest("not json", "r"))
        .includes("manifest-invalid-json"));
    assert.ok(codes(Model.parseWorkspaceManifest("[1]", "r"))
        .includes("manifest-not-object"));
});

test("parseWorkspaceManifest rejects byte, depth, project, and dependency limits", () => {
    assert.ok(codes(Model.parseWorkspaceManifest(" ".repeat(65537), "r"))
        .includes("manifest-too-large"));
    const deep = "[".repeat(13) + "]".repeat(13);
    assert.ok(codes(Model.parseWorkspaceManifest(deep, "r"))
        .includes("manifest-too-deep"));
    const projects = Array.from({ length: 33 }, (_, index) => ({
        id: `p${index}`, command: "npm start",
    }));
    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({ localwrap: 1, projects }), "r"))
        .includes("projects-limit"));
    const dependencies = Array.from({ length: 17 }, (_, index) => `p${index}`);
    const limited = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1, projects: [{ id: "main", command: "npm start", dependsOn: dependencies }],
    }), "r");
    assert.ok(codes(limited).includes("depends-on-limit"));
});

test("parseWorkspaceManifest validates commands, ports, urls, and paths per project", () => {
    const result = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [
            { id: "a", command: "make dev" },
            { id: "b", command: "npm start", port: 80 },
            { id: "c", command: "npm start", url: "http://example.com:3000" },
            { id: "d", command: "npm start", path: "/abs" },
            { id: "e", command: "npm start", port: 3000.5 },
        ],
    }), "repo");
    assert.equal(result.ok, false);
    const found = codes(result);
    assert.ok(found.includes("command-invalid"));
    assert.ok(found.includes("port-invalid"));
    assert.ok(found.includes("url-invalid"));
    assert.ok(found.includes("path-invalid"));
});

test("parseWorkspaceManifest normalises explicit IDs and resolves references through slugs", () => {
    const result = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [
            { id: "Web App", command: "npm run dev", port: 3000 },
            { id: "api", command: "npm run api", port: 3001, dependsOn: ["Web App"] },
        ],
        workspaces: [{ id: "All", projects: ["Web App", "api"] }],
    }), "repo");
    assert.deepEqual(result.errors, []);
    assert.equal(result.projects[0].id, "web-app");
    assert.deepEqual(result.projects[1].dependsOn, ["web-app"]);
    assert.deepEqual(result.workspaces[0].projects, ["web-app", "api"]);
    assert.equal(result.workspaces[0].id, "all");
});

test("parseWorkspaceManifest uniquifies colliding derived IDs", () => {
    const result = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [
            { name: "Web", command: "npm run dev" },
            { name: "Web", command: "npm run dev" },
        ],
    }), "repo");
    assert.equal(result.ok, true);
    assert.equal(result.projects[0].id, "web");
    assert.equal(result.projects[1].id, "web-2");
});

test("parseWorkspaceManifest blocks unknown, self, and cyclic dependencies", () => {
    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ id: "a", command: "npm start", dependsOn: ["ghost"] }],
    }), "r")).includes("dependency-unknown"));

    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ id: "a", command: "npm start", dependsOn: ["a"] }],
    }), "r")).includes("dependency-self"));

    assert.ok(codes(Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [
            { id: "a", command: "npm start", dependsOn: ["b"] },
            { id: "b", command: "npm start", dependsOn: ["a"] },
        ],
    }), "r")).includes("dependency-cycle"));
});

test("parseWorkspaceManifest validates workspace groupings", () => {
    const unknownRef = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ id: "a", command: "npm start" }],
        workspaces: [{ id: "w", projects: ["ghost"] }],
    }), "r");
    assert.ok(codes(unknownRef).includes("workspace-reference-unknown"));

    const empty = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ id: "a", command: "npm start" }],
        workspaces: [{ id: "w", projects: [] }],
    }), "r");
    assert.ok(codes(empty).includes("workspace-projects-required"));

    const unknownField = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ id: "a", command: "npm start" }],
        workspaces: [{ id: "w", projects: ["a"], color: "red" }],
    }), "r");
    assert.ok(codes(unknownField).includes("workspace-unknown-field"));
});

test("parseWorkspaceManifest warns without blocking on url/port mismatch", () => {
    const result = Model.parseWorkspaceManifest(JSON.stringify({
        localwrap: 1,
        projects: [{ id: "a", command: "npm start", port: 3000, url: "http://127.0.0.1:3001" }],
    }), "r");
    assert.equal(result.ok, true);
    assert.equal(result.warnings.length, 1);
    assert.equal(result.warnings[0].code, "url-port-mismatch");
});

test("parseRepositoriesConfig expands ~, requires absolute paths, rejects unknowns", () => {
    const parsed = Model.parseRepositoriesConfig(JSON.stringify({
        repositories: ["/home/me/src/storefront/", "~/src/blog"],
    }), "/home/me");
    assert.equal(parsed.ok, true);
    assert.deepEqual(parsed.repositories, ["/home/me/src/storefront", "/home/me/src/blog"]);

    assert.equal(Model.parseRepositoriesConfig(JSON.stringify({ repositories: ["relative/path"] }), "/home/me").ok, false);
    assert.equal(Model.parseRepositoriesConfig(JSON.stringify({ repositories: ["/a", "/a"] }), "/home/me").ok, false);
    assert.equal(Model.parseRepositoriesConfig(JSON.stringify({ repositories: ["/a"], autostart: true }), "/home/me").ok, false);
    assert.equal(Model.parseRepositoriesConfig(JSON.stringify({ repositories: "nope" }), "/home/me").ok, false);
    assert.equal(Model.parseRepositoriesConfig("bad", "/home/me").ok, false);
});

test("manifestCandidatePaths lists .localwrap/workspace.json before localwrap.json", () => {
    assert.deepEqual(Model.manifestCandidatePaths("/home/me/src/app/"), [
        "/home/me/src/app/.localwrap/workspace.json",
        "/home/me/src/app/localwrap.json",
    ]);
});

test("status summaries and bar label reflect ready, running, and attention counts", () => {
    const S = Model.STATUS;
    assert.equal(Model.barLabel(Model.summarizeStatuses([])), "LW");
    assert.equal(Model.barLabel(null), "LW");

    const summary = Model.summarizeStatuses([S.ready, S.ready, S.starting, S.failed, S.stopped]);
    assert.deepEqual(summary, { total: 5, running: 3, ready: 2, attention: 1 });
    assert.equal(Model.barLabel(summary), "LW 2/5!");
    assert.equal(Model.barLabel(Model.summarizeStatuses([S.ready])), "LW 1/1");
    assert.match(Model.barTooltip(summary), /2 of 5 ready/);
    assert.match(Model.barTooltip(summary), /1 need attention/);
});

test("canStart gates on dependencies being ready and on current status", () => {
    const S = Model.STATUS;
    const web = { id: "web", dependsOn: ["api"] };

    assert.equal(Model.canStart(web, { web: S.stopped, api: S.ready }).ok, true);
    const waiting = Model.canStart(web, { web: S.stopped, api: S.starting });
    assert.equal(waiting.ok, false);
    assert.match(waiting.reason, /api/);
    assert.equal(Model.canStart(web, { web: S.ready, api: S.ready }).ok, false);
    assert.equal(Model.canStart({ id: "api", dependsOn: [] }, { api: S.stopped }).ok, true);
});

test("readiness probe mirrors the app's HEAD/1s/<500 contract", () => {
    assert.deepEqual(Model.curlProbeArgv("http://127.0.0.1:3000/health"), [
        "curl", "-q", "--noproxy", "*", "--proto", "=http,https",
        "-s", "-o", "/dev/null", "-I",
        "-w", "%{http_code}", "--max-time", "1",
        "http://127.0.0.1:3000/health",
    ]);
    assert.equal(Model.isReadyHttpCode("200"), true);
    assert.equal(Model.isReadyHttpCode("404\n"), true);
    assert.equal(Model.isReadyHttpCode("499"), true);
    assert.equal(Model.isReadyHttpCode("500"), false);
    assert.equal(Model.isReadyHttpCode("000"), false);
    assert.equal(Model.isReadyHttpCode(""), false);
    assert.equal(Model.isReadyHttpCode("junk"), false);
    assert.equal(Model.READY_POLL_INTERVAL_MS, 500);
    assert.equal(Model.READY_TIMEOUT_MS, 30000);
});

test("appendOutputTail keeps a bounded, newline-split tail", () => {
    let tail = Model.appendOutputTail([], "line1\nline2\r\nline3", 4);
    assert.deepEqual(tail, ["line1", "line2", "line3"]);
    tail = Model.appendOutputTail(tail, "line4\nline5", 4);
    assert.deepEqual(tail, ["line2", "line3", "line4", "line5"]);
    assert.deepEqual(Model.appendOutputTail([], "", 4), []);
    assert.equal(Model.appendOutputTail([], "x".repeat(5000), 4)[0].length, 2048);
});

test("parseRepositoriesConfig rejects byte, depth, and repository-count limits", () => {
    assert.equal(Model.parseRepositoriesConfig(" ".repeat(16385), "/home/me").ok, false);
    assert.equal(Model.parseRepositoriesConfig("[".repeat(13) + "]".repeat(13), "/home/me").ok, false);
    const repositories = Array.from({ length: 17 }, (_, index) => `/repo/${index}`);
    const result = Model.parseRepositoriesConfig(JSON.stringify({ repositories }), "/home/me");
    assert.equal(result.ok, false);
    assert.equal(result.errors[0].code, "config-repositories-limit");
});

test("path helpers behave on edges", () => {
    assert.equal(Model.basename("/home/me/src/app/"), "app");
    assert.equal(Model.basename("app"), "app");
    assert.equal(Model.joinPath("/root/", "."), "/root");
    assert.equal(Model.joinPath("/root", "apps/web"), "/root/apps/web");
    assert.equal(Model.joinPath("/root", "./apps/web/"), "/root/apps/web");
});

test("parseRepositoriesConfig accepts opt-in flags that default to off", () => {
    const defaults = Model.parseRepositoriesConfig(JSON.stringify({ repositories: ["/a"] }), "/home/me");
    assert.equal(defaults.ok, true);
    assert.equal(defaults.notifications, false);
    assert.equal(defaults.openOnReady, false);

    const enabled = Model.parseRepositoriesConfig(JSON.stringify({
        repositories: ["/a"], notifications: true, openOnReady: true,
    }), "/home/me");
    assert.equal(enabled.ok, true);
    assert.equal(enabled.notifications, true);
    assert.equal(enabled.openOnReady, true);

    const badType = Model.parseRepositoriesConfig(JSON.stringify({
        repositories: ["/a"], notifications: "yes",
    }), "/home/me");
    assert.equal(badType.ok, false);
    assert.equal(badType.errors[0].code, "config-notifications-invalid");
});

const PLAN_PROJECTS = [
    { id: "db", dependsOn: [] },
    { id: "api", dependsOn: ["db"] },
    { id: "web", dependsOn: ["api"] },
    { id: "docs", dependsOn: [] },
];

test("workspaceStartPlan orders dependencies first and pulls in transitive deps", () => {
    assert.deepEqual(
        Model.workspaceStartPlan(PLAN_PROJECTS, { projects: ["web", "docs"] }),
        ["db", "api", "web", "docs"]);
    // A workspace listing only the leaf still starts its whole chain.
    assert.deepEqual(
        Model.workspaceStartPlan(PLAN_PROJECTS, { projects: ["web"] }),
        ["db", "api", "web"]);
    // Diamond: d depends on b and c, both depend on a.
    const diamond = [
        { id: "a", dependsOn: [] },
        { id: "b", dependsOn: ["a"] },
        { id: "c", dependsOn: ["a"] },
        { id: "d", dependsOn: ["b", "c"] },
    ];
    assert.deepEqual(
        Model.workspaceStartPlan(diamond, { projects: ["d"] }),
        ["a", "b", "c", "d"]);
});

test("orchestrationStep starts eligible members, waits, halts, and completes", () => {
    const S = Model.STATUS;
    const byID = {};
    for (const project of PLAN_PROJECTS) byID[project.id] = project;
    const plan = ["db", "api", "docs", "web"];

    const initial = Model.orchestrationStep(plan, byID, {});
    assert.deepEqual(initial.startNow, ["db", "docs"]);
    assert.deepEqual(initial.waiting, ["api", "web"]);
    assert.equal(initial.done, false);
    assert.equal(initial.blocked, null);

    const midway = Model.orchestrationStep(plan, byID,
        { db: S.ready, docs: S.starting, api: S.stopped, web: S.stopped });
    assert.deepEqual(midway.startNow, ["api"]);
    assert.deepEqual(midway.waiting, ["docs", "web"]);

    const halted = Model.orchestrationStep(plan, byID,
        { db: S.ready, docs: S.ready, api: S.failed, web: S.stopped });
    assert.deepEqual(halted.blocked, { id: "api", status: S.failed });
    assert.equal(halted.done, false);
    assert.deepEqual(halted.startNow, []);

    const done = Model.orchestrationStep(plan, byID,
        { db: S.ready, docs: S.ready, api: S.ready, web: S.ready });
    assert.equal(done.done, true);
    assert.equal(done.readyCount, 4);
});

test("workspaceStopPlan stops dependents before dependencies, running only", () => {
    const S = Model.STATUS;
    assert.deepEqual(
        Model.workspaceStopPlan(["db", "api", "docs", "web"],
            { db: S.ready, api: S.ready, docs: S.stopped, web: S.starting }),
        ["web", "api", "db"]);
    assert.deepEqual(Model.workspaceStopPlan(["db"], { db: S.stopped }), []);
});

test("watch helpers build stat argv and parse mtimes, including spaced paths", () => {
    const paths = Model.watchPathsFor("/home/me/.config/localwrap/repositories.json", ["/home/me/my src"]);
    assert.deepEqual(paths, [
        "/home/me/.config/localwrap/repositories.json",
        "/home/me/my src/.localwrap/workspace.json",
        "/home/me/my src/localwrap.json",
    ]);
    assert.deepEqual(Model.statWatchArgv(["/a", "/b"]),
        ["stat", "-c", "%n %Y", "/a", "/b"]);

    const times = Model.parseStatTimes(
        "/home/me/my src/localwrap.json 1755900000\n/a/b.json 1755900001\nnoise\n");
    assert.deepEqual(times, {
        "/home/me/my src/localwrap.json": "1755900000",
        "/a/b.json": "1755900001",
    });
    assert.equal(Model.sameStatTimes(times, { ...times }), true);
    assert.equal(Model.sameStatTimes(times, { ...times, "/a/b.json": "1755900002" }), false);
    assert.equal(Model.sameStatTimes(times, {}), false);
    assert.equal(Model.WATCH_POLL_INTERVAL_MS, 5000);
});

test("notifications cover notable transitions only and build a safe argv", () => {
    const S = Model.STATUS;
    assert.deepEqual(Model.notificationForTransition("Web", S.ready, "http://localhost:3000"),
        { summary: "Web is ready", body: "http://localhost:3000" });
    assert.equal(Model.notificationForTransition("Web", S.failed, "code 1").summary, "Web failed");
    assert.notEqual(Model.notificationForTransition("Web", S.conflict, ""), null);
    assert.notEqual(Model.notificationForTransition("Web", S.stalled, ""), null);
    assert.equal(Model.notificationForTransition("Web", S.starting, ""), null);
    assert.equal(Model.notificationForTransition("Web", S.stopped, ""), null);

    assert.deepEqual(Model.notifySendArgv("Web is ready", "http://localhost:3000"),
        ["notify-send", "-a", "LocalWrap", "--", "Web is ready", "http://localhost:3000"]);
    assert.deepEqual(Model.notifySendArgv("Web failed", ""),
        ["notify-send", "-a", "LocalWrap", "--", "Web failed"]);
});

test("dirCheckArgv wraps test -d", () => {
    assert.deepEqual(Model.dirCheckArgv("/repo/apps/web"), ["test", "-d", "/repo/apps/web"]);
});
