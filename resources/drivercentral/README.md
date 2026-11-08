# DriverCentral images

Marketing images for the TP-Link Kasa and Tapo listing (DriverCentral product 976). Each image is an HTML page rendered to PNG, and the rendered PNGs sit next to their sources.

| Path | Size | Used for |
| --- | --- | --- |
| `banners/spotlight-4096x848` | 4096x848 | DriverCentral homepage spotlight banner (emailed to DriverCentral, not uploaded) |
| `banners/launch-post-2400x1200` | 2400x1200 | Launch posts (c4forums, Reddit, Discord) |
| `banners/facts-strip-2400x136` | 2400x136 | The first image in the listing's description: four facts in a row, three-quarters of the width, on a transparent background. Put it in a plain paragraph in the description, not a heading, which adds its own spacing |
| `product-card-300x300.png` | 300x300 | The listing's product card, written by `make icons` from `resources/Driver Icons.sketch` |
| `photos/1-...` to `photos/5-...` | 2000x2000 | Listing photos, uploaded in number order |

`assets/` holds what the pages share: the Finite Labs logo, `scene.js`, which draws the banners' art, and TP-Link's logo as `brand-mark.svg`: the white version tp-link.com serves for dark backgrounds (https://static.tp-link.com/assets/images/icon/logo-white.svg), used as is. TP-Link publishes no brand kit and no mark on its own, so the banners and the photo frame show the whole logo.

The banners' art is `mesh`: plugs, power strips, bulbs, light strips, keypad buttons and power readings linked to the logo, set on each banner's `<svg class="scene">`. The template's DriverCentral README lists the styles, and the headline, chips and subtitle shrink until they end clear of the art.

## Rendering

```bash
resources/drivercentral/render.sh
```

This needs Google Chrome, python3 and a network connection (the pages load Inter from Google Fonts). It renders every page at 2x and overwrites the PNGs. Pass a directory to render somewhere else instead.

Chrome sometimes hangs on a page. After 60 seconds on one page, `render.sh` stops Chrome and fails, naming the page; run it again. `RENDER_TIMEOUT` sets the limit in seconds.

## Listing photos

Every photo is `photos/frame.html` around one screenshot from `photos/sources/`. Each line of `photos/photos.txt` is `<output name>|<query>`, and the query sets the fields below. `crop`, `end` and `tail` are pixels of the screenshot scaled to the card's 880 px width.

- `t`, `s`: the title and subtitle.
- `img`: the screenshot in `photos/sources/`.
- `crop`: pixels cut from the top of the screenshot.
- `end`: the height kept fully visible below `crop`.
- `tail`: extra rows under `end` that fade out, for a list that continues; `bg` is the fade color and `more` the text over it.
- `fit=1`: scale the whole screenshot to fit instead.

The DriverCentral viewer hides about the bottom 15% of a square photo until the popup is scrolled, so the frame keeps everything above that line (`SAFE` in `frame.html`).

The screenshots come from Composer on the dev controller running the DriverCentral build. The output names, powers and states, the device name and MAC address, and the License Activated status are demo values set for the shots, and the setup photo's IP address is a placeholder. In the Connections and Programming trees the project name and every item but the two TP-Link drivers are blurred. The setup crop stops above the TP-Link account fields. Retake a screenshot when the view it shows changes, then rerender.
