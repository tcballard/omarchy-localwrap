<h1 align="center">LocalWrap for Omarchy</h1>

<p align="center">
  <a href="https://github.com/tcballard/omarchy-badges"><img src="https://raw.githubusercontent.com/tcballard/omarchy-badges/75975e5b5bf75e7ede3764bcd2950046f7abfe2c/badges/v1/omarchy-plugin.svg" alt="Built for Omarchy: Plugin" height="24"></a>
</p>

**Your development projects, within reach.**

Start, monitor and stop local development projects from the Omarchy bar. LocalWrap reads a workspace manifest in each repository, shows the commands it will run, and opens your local app when it is ready.

## Everyday use

Open LocalWrap, add a repository and review its projects. **Start** shows the exact command and working directory before **Confirm & Start** runs it. Start dependencies in order, watch readiness, or stop a workspace’s processes together.

## Install

Omarchy Quattro, Python 3, curl, stat and the runtimes your projects use. Optional notifications use notify-send.

```bash
omarchy plugin add https://github.com/tcballard/omarchy-localwrap.git --enable
```

## Update and remove

Update:

```bash
omarchy plugin update io.github.tcballard.localwrap
```

Remove:

```bash
omarchy plugin remove io.github.tcballard.localwrap
```

## A few useful details

Each repository needs a [LocalWrap workspace manifest](GUIDE.md#configure). Nothing autostarts, and app URLs must use numeric loopback addresses such as `127.0.0.1`. Try the included [demo workspace](examples/demo).

Removing the plugin stops supervised process groups but leaves your repositories and configuration. [Execution review](GUIDE.md#execution-review) · [Development checks](GUIDE.md#development-and-verification)

[Usage and development guide](GUIDE.md) · [Report a bug](https://github.com/tcballard/omarchy-localwrap/issues)

[Apache-2.0 licensed](LICENSE).

<!-- Preserve links to sections now in the guide. -->
<a id="commands-and-origins"></a>
<a id="configure"></a>
<a id="development-and-verification"></a>
<a id="execution-review"></a>
<a id="files-and-bounded-parsing"></a>
<a id="installation"></a>
<a id="license"></a>
<a id="network-processes-output-and-rendering"></a>
<a id="remove"></a>
<a id="requirements"></a>
<a id="security-model"></a>
<a id="what-it-does"></a>

[Looking for the previous detailed sections? Open the full guide →](GUIDE.md)
