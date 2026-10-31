// secrets im os-keyring, ueber den freedesktop secret service direkt am
// session-bus (gnome-keyring, kwallet, keepassxc reden alle dieses protokoll).
//
// portiert aus attek-orga/lib/keyring.js. ersetzt @napi-rs/keyring: kein natives
// modul mehr, damit tools/ ohne prebuild in andere projekte kopierbar bleibt.
//
// WICHTIG, attribut-layout: die eintraege folgen weiter dem schema, das
// @napi-rs/keyring (keyring-rs) geschrieben hat, also service + USERNAME (nicht
// "account" wie in attek-orga) + xdg:schema, label "keyring:<account>@<service>".
// nur so findet diese implementierung einen schon gespeicherten token wieder und
// niemand muss den browser-consent nochmal durchlaufen.

import { connect } from "./dbus.mjs";

const DESTINATION = "org.freedesktop.secrets";
const SERVICE_PATH = "/org/freedesktop/secrets";
const DEFAULT_COLLECTION = "/org/freedesktop/secrets/aliases/default";
const IFACE = {
  service: "org.freedesktop.Secret.Service",
  collection: "org.freedesktop.Secret.Collection",
  item: "org.freedesktop.Secret.Item",
  prompt: "org.freedesktop.Secret.Prompt",
};

function attributesOf(service, account) {
  return [
    ["service", service],
    ["username", account],
    ["xdg:schema", "org.freedesktop.Secret.Generic"],
  ];
}

// oeffnet bus + session, raeumt danach immer auf
async function withService(fn) {
  let bus;
  try {
    bus = await connect();
  } catch {
    return { ok: false, reason: "kein session-bus erreichbar" };
  }
  try {
    const [, session] = await bus.call({
      destination: DESTINATION,
      path: SERVICE_PATH,
      iface: IFACE.service,
      member: "OpenSession",
      signature: "sv",
      body: ["plain", { signature: "s", value: "" }],
    });
    return { ok: true, value: await fn(bus, session) };
  } catch (e) {
    return { ok: false, reason: e.message };
  } finally {
    bus.close();
  }
}

// ein prompt-pfad ungleich "/" heisst: der nutzer muss erst bestaetigen
// (gesperrter keyring). das fenster oeffnet der daemon, wir warten nur.
async function resolvePrompt(bus, promptPath) {
  if (!promptPath || promptPath === "/") return true;
  return new Promise((resolve, reject) => {
    const done = bus.onSignal((message) => {
      if (message.path !== promptPath || message.member !== "Completed") return;
      done();
      const [dismissed] = message.body;
      resolve(!dismissed);
    });
    bus
      .call({
        destination: "org.freedesktop.DBus",
        path: "/org/freedesktop/DBus",
        iface: "org.freedesktop.DBus",
        member: "AddMatch",
        signature: "s",
        body: [`type='signal',interface='${IFACE.prompt}',path='${promptPath}'`],
      })
      .then(() =>
        bus.call({
          destination: DESTINATION,
          path: promptPath,
          iface: IFACE.prompt,
          member: "Prompt",
          signature: "s",
          body: [""],
        }),
      )
      .catch((e) => {
        done();
        reject(e);
      });
  });
}

async function findItems(bus, service, account) {
  const [unlocked, locked] = await bus.call({
    destination: DESTINATION,
    path: SERVICE_PATH,
    iface: IFACE.service,
    member: "SearchItems",
    signature: "a{ss}",
    body: [attributesOf(service, account)],
  });
  if (unlocked.length) return unlocked;
  if (!locked.length) return [];

  const [opened, promptPath] = await bus.call({
    destination: DESTINATION,
    path: SERVICE_PATH,
    iface: IFACE.service,
    member: "Unlock",
    signature: "ao",
    body: [locked],
  });
  if (opened.length) return opened;
  return (await resolvePrompt(bus, promptPath)) ? locked : [];
}

// one keyring slot, same shape the rest of tools/ already used
export function entry(service, account) {
  return {
    async get() {
      const res = await withService(async (bus, session) => {
        const items = await findItems(bus, service, account);
        if (!items.length) return null;
        const [secret] = await bus.call({
          destination: DESTINATION,
          path: items[0],
          iface: IFACE.item,
          member: "GetSecret",
          signature: "o",
          body: [session],
        });
        // secret ist (session, parameters, value, content_type)
        const value = secret[2];
        return value && value.length ? value.toString("utf8") : null;
      });
      return res.ok ? res.value : null;   // nichts gespeichert, oder keyring zu
    },

    async set(token) {
      const res = await withService(async (bus, session) => {
        const [, promptPath] = await bus.call({
          destination: DESTINATION,
          path: DEFAULT_COLLECTION,
          iface: IFACE.collection,
          member: "CreateItem",
          signature: "a{sv}(oayays)b",
          body: [
            [
              ["org.freedesktop.Secret.Item.Label",
                { signature: "s", value: `keyring:${account}@${service}` }],
              ["org.freedesktop.Secret.Item.Attributes",
                { signature: "a{ss}", value: attributesOf(service, account) }],
            ],
            [session, Buffer.alloc(0), Buffer.from(token, "utf8"), "text/plain"],
            true,   // vorhandenen eintrag ersetzen
          ],
        });
        return resolvePrompt(bus, promptPath);
      });
      if (!res.ok) throw new Error(`keyring write failed: ${res.reason}`);
      if (!res.value) throw new Error("keyring write cancelled (dialog dismissed)");
    },

    async clear() {
      const res = await withService(async (bus) => {
        const items = await findItems(bus, service, account);
        for (const item of items) {
          const [promptPath] = await bus.call({
            destination: DESTINATION,
            path: item,
            iface: IFACE.item,
            member: "Delete",
          });
          await resolvePrompt(bus, promptPath);
        }
        return items.length > 0;
      });
      return res.ok && res.value;
    },
  };
}
