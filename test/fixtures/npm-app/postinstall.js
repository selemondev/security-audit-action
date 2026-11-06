const fs = require("node:fs");

fs.writeFileSync(
  "install-probe.json",
  JSON.stringify({
    env: Object.keys(process.env).sort(),
    gitConfig: fs.existsSync(".git/config"),
  }),
);
fs.appendFileSync("tracked.txt", "changed by postinstall\n");
