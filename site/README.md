# site/

Put the cover website here. Required: `index.html`. Optional: `404.html`,
`styles.css`, images, `favicon.svg` and other pages.

The page is generated with ChatGPT or DeepSeek using the prompt in
[`docs/SITE-PROMPT.md`](../docs/SITE-PROMPT.md). After changing files run
`docker compose restart`.

This README and dot-files are not published: the entrypoint skips them when it
copies the directory into the container. `site/` is mounted, so a simple
`docker compose restart` is enough after editing.
