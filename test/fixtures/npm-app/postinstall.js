const fs = require("node:fs");

fs.writeFileSync(
  "install-probe.json",
  JSON.stringify({
    env: Object.keys(process.env).sort(),
    credentials: [".git/config", "lib/.git/config", "gha-creds-test.json"].filter((path) => fs.existsSync(path)),
  }),
);
fs.appendFileSync("tracked.txt", "changed by postinstall\n");
