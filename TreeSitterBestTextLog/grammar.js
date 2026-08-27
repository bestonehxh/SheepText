const ci = (word) => new RegExp(
  word
    .split("")
    .map((ch) => {
      const lower = ch.toLowerCase();
      const upper = ch.toUpperCase();
      return lower === upper ? ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") : `[${lower}${upper}]`;
    })
    .join("")
);

module.exports = grammar({
  name: "besttext_log",

  extras: $ => [
    /[ \t]+/,
  ],

  rules: {
    source_file: $ => repeat(choice(
      $.timestamp,
      $.ipv4_address,
      $.ipv6_address,
      $.mac_address,
      $.vlan,
      $.interface_name,
      $.severity_error,
      $.severity_warning,
      $.severity_success,
      $.network_keyword,
      $.prompt,
      $.compound_identifier,
      $.number,
      $.word,
      $.punctuation,
      $.newline
    )),

    newline: _ => /\r?\n/,

    timestamp: _ => token(prec(9, choice(
      /\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?/,
      /\d{2}:\d{2}:\d{2}(\.\d+)?/,
      /[A-Z][a-z]{2}[ \t]+\d{1,2}[ \t]+\d{2}:\d{2}:\d{2}/
    ))),

    ipv4_address: _ => token(prec(8, /\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?/)),

    ipv6_address: _ => token(prec(7, /[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}(\/\d{1,3})?/)),

    mac_address: _ => token(prec(8, choice(
      /[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}/,
      /[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}/,
      /[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}/
    ))),

    vlan: _ => token(prec(7, /[Vv][Ll][Aa][Nn][ \t-]*\d{1,4}/)),

    interface_name: _ => token(prec(6, choice(
      /[Hh][Uu]\d+([\/.:_-]\d+)*/,
      /[Ff][Oo]\d+([\/.:_-]\d+)*/,
      /[Tt][Ee]\d+([\/.:_-]\d+)*/,
      /[Gg][Ii]\d+([\/.:_-]\d+)*/,
      /[Ff][Aa]\d+([\/.:_-]\d+)*/,
      /[Pp][Oo]\d+([\/.:_-]\d+)*/,
      /[Ll][Oo]\d+([\/.:_-]\d+)*/,
      /[Ee][Tt][Hh]\d+([\/.:_-]\d+)*/,
      /[Vv][Ll][Aa][Nn]\d+/,
      /[Mm][Gg][Mm][Tt]\d*/,
      /[Ee][Tt][Hh][Ee][Rr][Nn][Ee][Tt]\d+([\/.:_-]\d+)*/,
      /[Gg][Ii][Gg][Aa][Bb][Ii][Tt][Ee][Tt][Hh][Ee][Rr][Nn][Ee][Tt]\d+([\/.:_-]\d+)*/,
      /[Tt][Ee][Nn][Gg][Ii][Gg][Aa][Bb][Ii][Tt][Ee][Tt][Hh][Ee][Rr][Nn][Ee][Tt]\d+([\/.:_-]\d+)*/,
      /[Ff][Aa][Ss][Tt][Ee][Tt][Hh][Ee][Rr][Nn][Ee][Tt]\d+([\/.:_-]\d+)*/,
      /[Pp][Oo][Rr][Tt]-[Cc][Hh][Aa][Nn][Nn][Ee][Ll]\d+([\/.:_-]\d+)*/,
      /[Ll][Oo][Oo][Pp][Bb][Aa][Cc][Kk]\d+([\/.:_-]\d+)*/,
      /[Tt][Uu][Nn][Nn][Ee][Ll]\d+([\/.:_-]\d+)*/,
      /[Mm][Aa][Nn][Aa][Gg][Ee][Mm][Ee][Nn][Tt]\d+([\/.:_-]\d+)*/
    ))),

    severity_error: _ => token(prec(5, choice(
      ci("emergency"),
      ci("alert"),
      ci("critical"),
      ci("crit"),
      ci("error"),
      ci("err"),
      ci("failed"),
      ci("fail"),
      ci("failure"),
      ci("down"),
      ci("deny"),
      ci("denied"),
      ci("block"),
      ci("blocked"),
      ci("disable"),
      ci("disabled")
    ))),

    severity_warning: _ => token(prec(5, choice(
      ci("warning"),
      ci("warn")
    ))),

    severity_success: _ => token(prec(5, choice(
      ci("ok"),
      ci("okay"),
      ci("done"),
      ci("pass"),
      ci("passed"),
      ci("allow"),
      ci("allowed"),
      ci("enable"),
      ci("enabled"),
      /[Nn][Oo][ \t]+[Ss][Hh][Uu][Tt][Dd][Oo][Ww][Nn]/,
      ci("permit"),
      ci("permits"),
      ci("permitted"),
      ci("permite"),
      ci("up"),
      ci("success")
    ))),

    network_keyword: _ => token(prec(4, choice(
      ci("notice"),
      ci("info"),
      ci("debug"),
      ci("trace"),
      ci("interface"),
      ci("hostname"),
      ci("router"),
      ci("route"),
      ci("access-list"),
      ci("acl"),
      ci("ip"),
      ci("ipv6"),
      ci("address"),
      ci("mac"),
      ci("arp"),
      ci("nat"),
      ci("dhcp"),
      ci("snmp"),
      ci("ntp"),
      ci("dns"),
      ci("vrf"),
      ci("ospf"),
      ci("bgp"),
      ci("vrrp"),
      ci("hsrp"),
      ci("lacp"),
      ci("stp"),
      ci("ssh"),
      ci("telnet"),
      ci("show"),
      ci("set"),
      ci("config"),
      ci("configuration"),
      ci("enable"),
      ci("shutdown"),
      ci("description")
    ))),

    prompt: _ => token(prec(4, /[A-Za-z0-9_.@-]+[>#]/)),

    compound_identifier: _ => token(prec(3, /[A-Za-z_][A-Za-z0-9_.-]*(\/[A-Za-z0-9_.:-]+)+/)),

    number: _ => token(prec(2, /\d+(\.\d+)?/)),

    word: _ => /[A-Za-z_][A-Za-z0-9_.@/-]*/,

    punctuation: _ => /[^\sA-Za-z0-9_]/,
  }
});
