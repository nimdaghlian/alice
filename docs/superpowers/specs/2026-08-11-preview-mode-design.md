# Preview Mode — live-reload editing on the kiosk

> **Status: DRAFT, deferred.** Not to be implemented before the first successful install. This adds a
> vhost, a firewall port, an attendant alias, and a second Eleventy process to a configuration that
> has never been evaluated by Nix or booted on hardware. Build it once `http://alice` demonstrably
> works.

## Problem

The attendant's editing loop is: import assets → run `make-gallery` → edit the generated Markdown in
Obsidian (titles, descriptions, tags) → look at the result. Only the third step is iterative, and
only Markdown changes are involved — the assets are already in place and untouched.

Today that loop requires a manual browser refresh. `eleventy --watch` rebuilds into
`/srv/www/alice` on every save, so the content is always current, but nothing tells the browser to
reload. Eleventy's own dev server (`--serve`) provides exactly that via live reload, and this spec is
about making it usable on Alice.

## Why the obvious approach fails

Running `eleventy --serve` alongside the production setup does not work, for a reason that is easy to
get wrong: **root-relative URLs resolve against the origin that served the page, not against whatever
other server happens to be running.**

Records emit asset URLs like `/library/trees/oak.jpg` (from `libraryUrl: /library/`). Viewing a page
at `http://alice:8080` makes the browser request `http://alice:8080/library/trees/oak.jpg`. nginx —
listening on port 80 with the library — is never consulted. The request goes to Eleventy's dev
server, which cannot serve it.

That last part is a hard restriction, not a configuration gap. The dev server has an `aliases` option
mapping URL prefixes to filesystem paths, which looks like the escape hatch, but
`@11ty/eleventy-dev-server/server.js:238` gates it:

```js
let alias = this.matchPassthroughAlias(filepath);
if (alias) {
  if (!this.isFileInDirectory(path.resolve("."), alias)) {
    throw new Error("Invalid path");
  }
```

`path.resolve(".")` is the working directory — the memex2 checkout. An alias pointing at
`/srv/library` resolves outside it and throws. This is the same project-directory containment rule
that makes external library mode necessary in the first place (Eleventy rejects passthrough sources
outside the project), enforced at a second layer.

So in external mode, Eleventy's dev server can serve the HTML and nothing else.

## Design

Keep Eleventy serving only what it can, and put it behind nginx so the browser sees **one origin**.
nginx continues to serve `/library/` from disk and proxies everything else to the dev server.

```nix
virtualHosts."alice-preview" = {
  listen = [ { addr = "0.0.0.0"; port = 8081; } ];

  locations."/" = {
    proxyPass = "http://127.0.0.1:8080";   # Eleventy's dev server
    proxyWebsockets = true;                # live-reload socket
  };

  locations."/library/" = {
    alias = "${cfg.libraryPath}/";         # same disk production serves
  };
};
```

Result:

| URL | Serves | Purpose |
|---|---|---|
| `http://alice` | static build from `/srv/www/alice` + `/library/` | visitors |
| `http://alice:8081` | proxied Eleventy dev server + `/library/` | attendant editing |

Because both locations are on one origin, `/library/...` resolves to nginx in both modes and
`libraryUrl` stays `/library/`. No absolute origins are introduced anywhere, and no memex2-side
configuration differs between production and preview.

`proxyWebsockets = true` is load-bearing: Eleventy's live reload is a websocket, and without the
upgrade headers the rebuild still happens but the browser never refreshes — losing the only feature
this spec exists to provide.

### Starting and stopping

Preview is **not** a always-on service. It's an attendant alias that runs in the foreground:

```
preview-site      # runs `eleventy --serve --port 8080` in the checkout; Ctrl-C to stop
```

Foreground rather than a systemd unit, because it's a deliberate, temporary mode — the attendant
should be able to see it running and stop it by closing the terminal, without learning `systemctl`.
The alias should print the preview URL on startup.

Production `eleventy --watch` keeps running throughout. Two Eleventy processes then watch the same
source: mildly wasteful in CPU and inotify watches, but harmless, since they write to different
output directories and neither writes to the source.

### Firewall

Port 8081 needs opening on the AP interface, alongside the existing 80:

```nix
networking.firewall.interfaces.${apInterface}.allowedTCPPorts = [ 80 8081 ];
```

Port 8080 is **not** opened — the dev server binds loopback-visible only as far as visitors are
concerned, reachable exclusively through nginx's proxy. Whether Eleventy's dev server binds `0.0.0.0`
by default is unconfirmed; if it does, it is unreachable from the AP anyway because the firewall does
not open 8080. Worth confirming during implementation rather than relying on that.

## Alternative considered and rejected

**Absolute `libraryUrl`.** Setting `libraryUrl: http://alice/library/` makes asset URLs point at
nginx regardless of which server rendered the page (memex2's `assetUrl` filter passes absolute URLs
through untouched), so the dev server would work standalone with no proxy at all.

Rejected because it bakes an origin into production HTML. Visitors reaching the kiosk at
`http://10.0.0.1` would receive pages whose images point at `http://alice/...` — still functional,
since dnsmasq answers for every client on the AP, but it makes production output depend on name
resolution that has nothing to do with production. The proxy keeps production URLs origin-relative
and confines all preview-specific machinery to nginx.

## Testing

- `http://alice:8081` renders the collection, and a Markdown edit in Obsidian refreshes the browser
  without manual reload
- Images load in preview — this is the specific thing the naive approach gets wrong, so it is the
  test that matters most
- `http://alice` is unaffected while preview runs
- Stopping `preview-site` leaves production serving normally
- Port 8080 is not reachable from a device on the AP

## Files touched

- `nixos/modules/nginx.nix` — preview vhost, firewall port
- `nixos/modules/aliases.nix` — `preview-site`
- `docs/alice.md` — attendant workflow, alias table
- `README.md` — alias table

No memex2-side changes. The dev server is used exactly as it ships.
