# Blocked domains for the Squid proxy
# Used to prevent data exfiltration and access to risky sites

let
  categories = {
    pastebin_sites = [
      "pastebin.com" "hastebin.com" "paste.ee" "dpaste.org" "ghostbin.com"
      "privatebin.net" "0bin.net" "paste.debian.net" "bpaste.net"
    ];

    file_sharing = [
      "transfer.sh" "file.io" "tmpfiles.org" "gofile.io" "pixeldrain.com"
      "catbox.moe" "uguu.se" "filebin.net" "uploadfiles.io"
    ];

    url_shorteners = [
      "bit.ly" "tinyurl.com" "t.co" "goo.gl" "ow.ly" "is.gd" "buff.ly"
    ];

    webhook_sites = [
      "webhook.site" "requestbin.com" "hookbin.com" "pipedream.com"
      "beeceptor.com" "requestcatcher.com" "httpbin.org"
    ];

    code_execution = [
      "replit.com" "glitch.com" "codepen.io" "jsfiddle.net" "codesandbox.io"
    ];

    risky_tlds = [ "tk" "ml" "ga" "cf" "gq" "top" "xyz" "click" "link" ];
  };

  # Helper function that flattens all domain lists (excluding risky_tlds)
  allDomains =
    categories.pastebin_sites
    ++ categories.file_sharing
    ++ categories.url_shorteners
    ++ categories.webhook_sites
    ++ categories.code_execution;

in
  categories // { inherit allDomains; }
