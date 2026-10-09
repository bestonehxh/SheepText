@testable import SheepSyntaxKit
import NetworkHighlightKit

/// One realistic document per language, exercising the constructs that
/// cross lines — the ones the incremental pass has to get right.
enum Samples {
    static let all: [(SyntaxLanguage, String)] = [
        (.swift, swift), (.javascript, javascript), (.typescript, typescript), (.go, go), (.rust, rust),
        (.java, java), (.c, c), (.csharp, csharp), (.scala, scala), (.php, php), (.python, python),
        (.ruby, ruby), (.bash, bash), (.elixir, elixir), (.haskell, haskell), (.json, json), (.yaml, yaml),
        (.toml, toml), (.css, css), (.html, html), (.xml, xml), (.markdown, markdown), (.dockerfile, dockerfile),
        (.sql, sql), (.diff, diff), (.log, log), (.markdown, markdownParagraphs),
    ]

    /// Network config samples, one per shape of vendor table.
    static let network: [(Vendor, String)] = [
        (.cisco, cisco), (.arubaCX, aruba), (.huawei, huawei), (.juniper, juniper), (.auto, autoConfig),
    ]

    /// Every grammar the fuzz and the dumps cover.
    static let grammars: [(SyntaxGrammar, String)] =
        all.map { (SyntaxGrammar.language($0.0), $0.1) } + network.map { (SyntaxGrammar.networkConfig($0.0), $0.1) }

    static let cisco = #"""
    ! Cisco IOS
    hostname core-sw1
    vlan 10,20,30-40
    vlan 306s
    vlan internal allocation policy ascending
    spanning-tree mode rapid-pvst
    spanning-tree mode rpvsts
    spanning-tree vlan 1-10 priority 24576
    interface GigabitEthernet1/0/1
     description uplink to 10.0.0.1 add 5000 ports
     switchport trunk allowed vlan 10, 20, 5000
     switchport trunk allowed vlan add 30,4095
     switchport access vlan 100
     ip address 192.168.1.1 255.255.255.0
     mac-address aabb.ccdd.eeff
     no shutdown
    !
    banner motd ^C Authorized access only, vlan 9999 ^C
    snmp-server location ห้องเซิร์ฟเวอร์ ชั้น 3 🐑
    ntp server 2001:db8::1
    """#

    static let aruba = #"""
    ! AOS-CX
    hostname aruba-core
    vlan 10
        name users
    interface 1/1/1
        vlan trunk allowed 10,20-30
        ip address 10.1.0.1/24
        state connected up down warning
    """#

    static let huawei = #"""
    # Huawei VRP
    sysname CE-1
    vlan batch 10 20 30
    interface GE1/0/1
     port link-type trunk
     port trunk allow-pass vlan 10 20
     description link to core
    return
    """#

    static let juniper = #"""
    # Junos
    set interfaces ge-0/0/0 unit 0 family inet address 192.0.2.1/24
    set vlans users vlan-id 100
    set protocols ospf area 0.0.0.0 interface ge-0/0/0.0
    """#

    static let autoConfig = "notes\nserver 10.0.0.5 mac 00:11:22:33:44:55\u{2028}second on U+2028\u{85}after NEL 2001:db8::7\ncolour ก่ 🐑 up down\n"

    /// Long paragraphs with emphasis and strong that close lines later, and a
    /// setext heading, so the paragraph lookahead is exercised by the fuzz.
    static let markdownParagraphs = #"""
    A paragraph that opens *emphasis here
    and keeps it on this line
    until it closes* on the third.

    Another with **strong that
    spans** and _underscore
    emphasis_ and a `code span`.

    Heading made by a line
    ======================

    - item with *emphasis
      continued* in the item
    no closer here *at all
    and none here either
    """#

    static let swift = ##"""
    import Foundation

    /// A greeter.
    @MainActor
    final class Greeter<T: Hashable>: NSObject, Sendable {
        private let name: String
        var count = 0x1F + 1_000

        init(name: String) {
            self.name = name
        }

        func greet(_ other: T?) async throws -> String {
            /* a block
               /* nested */
               comment */
            guard let other else { return "nobody \(name)" }
            let raw = #"raw \(not) \#(name)"#
            let multi = """
                Hello, \(other) and \(name.uppercased())
                \t tab
                """
            return multi + raw + "\u{1F600}"
        }
    }

    #if DEBUG
    let items = [1, 2, 3].map { $0 * 2 }.filter { $0 > 2 }
    #endif
    extension Greeter { static func make() -> Greeter { .init(name: "x") } }
    """##

    static let javascript = #"""
    #!/usr/bin/env node
    import { readFile } from 'fs/promises';
    const re = /ab+c\/d[/]/gi, half = total / 2;
    /**
     * Doc comment
     */
    export default async function main(argv = process.argv) {
      const tpl = `Hello ${user.name + `nested ${deep}`} and
      a second line ${1 + 2}`;
      const obj = { key: 1, 'quoted': 2, default: 3, nested: { a: null } };
      class Foo extends Bar { #secret = 1; get value() { return this.#secret; } }
      const el = (
        <div className="app" onClick={() => setCount(count + 1)}>
          Hello {user.name}
          <Child prop={x} />
        </div>
      );
      return list.filter(x => x > 0).map((y) => y * 2);
    }
    """#

    static let typescript = #"""
    interface Props<T> extends Base {
      readonly name: string;
      items?: Array<T>;
    }
    type Handler = (event: Event) => void;
    enum Color { Red = 'red', Green = "green" }
    export class Service implements Api {
      constructor(private readonly http: HttpClient) {}
      async load<T>(id: number): Promise<T | undefined> {
        const cast = <T>value;
        const generic = identity<string>("x");
        return this.http.get<T>(`/items/${id}`);
      }
    }
    const x = a < b && c > d;
    """#

    static let go = #"""
    package main

    import (
    	"fmt"
    	"strings"
    )

    // Point is a point.
    type Point struct {
    	X, Y int
    }

    func (p *Point) String() string {
    	raw := `a raw
    string over lines`
    	r := 'x'
    	return fmt.Sprintf("%d,%d\n", p.X, p.Y) + raw + string(r)
    }

    func main() {
    	s := make([]int, 0, 10)
    	s = append(s, len(strings.Fields("a b")))
    	/* block */ fmt.Println(s, nil, true, 3.14e-2)
    }
    """#

    static let rust = #"""
    use std::collections::HashMap;

    #[derive(Debug, Clone)]
    pub struct Config<'a> {
        name: &'a str,
        values: HashMap<String, i32>,
    }

    impl<'a> Config<'a> {
        /// Doc
        pub fn new(name: &'a str) -> Self {
            let raw = r#"raw "quoted" string"#;
            let multi = "line one
    line two";
            let c = 'x'; let b = b'y';
            println!("{} {}", raw, multi);
            /* outer /* inner */ still */
            Self { name, values: HashMap::new() }
        }
    }

    macro_rules! square { ($x:expr) => { $x * $x }; }
    """#

    static let java = #"""
    package com.example;

    import java.util.List;

    @SuppressWarnings("unchecked")
    public final class Main extends Base implements Runnable {
        private static final int MAX_SIZE = 100;
        private String text = """
            A text block
            with "quotes"
            """;

        @Override
        public void run() {
            char c = '\n';
            List<String> items = List.of("a", "b");
            for (String item : items) { System.out.println(item + c); }
            /* block
               comment */
            return;
        }
    }
    """#

    static let c = #"""
    #include <stdio.h>
    #include "local.h"
    #define MAX(a, b) ((a) > (b) ? (a) : (b))
    #define LIMIT 100

    typedef struct node {
        int value;
        struct node *next;
    } node_t;

    /* A block
       comment */
    static int sum(const node_t *head) {
        int total = 0;
        for (const node_t *n = head; n != NULL; n = n->next) {
            total += n->value; // accumulate
        }
        printf("total: %d\n", total);
        return MAX(total, LIMIT) + 'a' + 0x1Fu + 1.5e3f;
    }
    """#

    static let csharp = #"""
    using System;
    using System.Collections.Generic;

    namespace Demo
    {
        #region Models
        public record Person(string Name, int Age);
        #endregion

        public class Program
        {
            public static void Main(string[] args)
            {
                var name = "world";
                var path = @"C:\temp\""file"".txt";
                var greeting = $"Hello {name}, {{literal}} {args.Length:D2}";
                var raw = """
                    Raw "text" here
                    """;
                char c = 'x';
                Console.WriteLine(greeting + path + raw + c);
            }
        }
    }
    """#

    static let scala = #"""
    package demo

    import scala.collection.mutable

    /** Doc */
    case class User(name: String, age: Int)

    object Main extends App {
      val greeting = s"Hello ${user.name} and $name"
      val multi = """line one
        |line two""".stripMargin
      val f = f"$pi%.2f"
      def add(a: Int, b: Int): Int = a + b
      /* nested /* comment */ ok */
      val c = 'x'
      val sym = 'symbol
      users.filter(_.age > 18).map(u => u.name)
    }
    """#

    static let php = #"""
    <!DOCTYPE html>
    <html>
    <head><title><?= $title ?></title></head>
    <body class="<?php echo $theme; ?>">
    <?php
    namespace App;

    use Foo\Bar;

    #[Attribute]
    final class User extends Model {
        private array $items = [];
        public function __construct(private string $name) {}
        public function greet(): string {
            // a comment
            $s = "Hello {$this->name} and $other->prop\n";
            $t = 'single $not';
            $doc = <<<EOT
            Heredoc with $name
            EOT;
            /* ?> inside a block comment */
            return strtoupper($s) . $t . $doc;
        }
    }
    ?>
    <script>
      const x = 1; // js
    </script>
    </body>
    </html>
    """#

    static let python = #"""
    #!/usr/bin/env python3
    """Module docstring
    over two lines."""
    from __future__ import annotations
    import os

    @dataclass(frozen=True)
    class Point(Base):
        x: int = 0
        y: float = 1.5e-3

        def distance(self, other: "Point") -> float:
            '''Method docstring.'''
            name = f"{self.x!r:>10} and {other.y + 1} {{braces}}"
            raw = rb'\d+'
            print(len(name), sep='', end=None)
            return (self.x ** 2 + other.y ** 2) ** 0.5

    match command:
        case "go":
            pass
    ALL_CAPS = True
    """#

    static let ruby = #"""
    # frozen_string_literal: true
    require 'json'

    =begin
    A block comment
    =end

    module Greeting
      class Greeter < Base
        attr_reader :name
        DEFAULT = "world".freeze

        def initialize(name = DEFAULT)
          @name = name
          @@count ||= 0
        end

        def greet(other:, loud: false)
          text = "Hello #{@name} and #{other.upcase}"
          list = %w[a b c]
          re = /h(e|a)llo/i
          doc = <<~EOS
            Heredoc #{name}
          EOS
          items.each { |item, index| puts item }
          text.empty? ? nil : text
        end
      end
    end
    """#

    static let bash = #"""
    #!/usr/bin/env bash
    set -euo pipefail

    NAME="world"
    readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    greet() {
      local who="${1:-$NAME}"
      echo "Hello, $who" >&2
    }

    for f in *.txt; do
      if [[ -f "$f" ]]; then
        cat "$f" | grep -v '^#' | wc -l
      fi
    done

    case "$1" in
      start) greet "$2" ;;
      *) echo 'unknown' ;;
    esac

    cat <<EOF
    Heredoc with $NAME and $(date)
    EOF
    apt-get install -y \
      curl \
      git
    """#

    static let elixir = #"""
    defmodule Demo.Greeter do
      @moduledoc """
      Greets people.
      """
      use GenServer

      @spec greet(String.t()) :: String.t()
      def greet(name) when is_binary(name) do
        message = "Hello #{name}!"
        regex = ~r/h(e|a)llo/i
        words = ~w(a b c)
        IO.puts(message)
        Enum.map([1, 2, 3], &(&1 * 2))
        %{key: :value, "str" => 1}
      end

      defp private_fun(_unused), do: nil
    end
    """#

    static let haskell = #"""
    {-# LANGUAGE OverloadedStrings #-}
    module Main (main) where

    import qualified Data.Map as Map
    import Data.List (sortBy)

    -- | A comment
    data Shape = Circle Double | Rect Double Double
      deriving (Show, Eq)

    {- block
       {- nested -}
       comment -}
    area :: Shape -> Double
    area (Circle r) = pi * r * r
    area (Rect w h) = w * h

    main :: IO ()
    main = do
      let xs = foldl' (+) 0 [1, 2, 3]
      putStrLn ("total: " ++ show xs)
      print ('c', Map.empty, x `div` 2)
    """#

    static let json = #"""
    {
      "name": "sheeptext",
      "version": 1.5,
      "enabled": true,
      "nothing": null,
      "list": [1, -2, 3e4, "a\nb"],
      // jsonc comment
      /* block
         comment */
      "nested": { "key": "value" }
    }
    """#

    static let yaml = #"""
    %YAML 1.2
    ---
    # Comment
    name: sheeptext
    version: 1.5
    enabled: true
    nothing: ~
    anchors:
      base: &base
        a: 1
      derived:
        <<: *base
        b: !!str 2
    list:
      - one
      - "two"
      - key: value
        run: |
          echo "block scalar"
          echo more
        after: done
    folded: >-
      folded text
      continues
    flow: {a: 1, b: [x, y]}
    quoted: "multi
      line"
    ...
    """#

    static let toml = #"""
    # Comment
    title = "TOML Example"

    [owner]
    name = "Tom"
    dob = 1979-05-27T07:32:00-08:00

    [database]
    enabled = true
    ports = [ 8000, 8001,
              8002 ]
    data = [ ["delta", "phi"], [3.14] ]
    temp_targets = { cpu = 79.5, case = 72.0 }

    [[products]]
    name = """
    Multi-line
    string"""
    literal = 'C:\path'
    "quoted key" = 0x1F
    """#

    static let css = #"""
    @import url("theme.css");
    /* A comment
       over lines */
    :root { --accent: #0A72D6; }

    body, .container > p:first-child::before {
      margin: 0 auto;
      color: var(--accent) !important;
      background: url(image.png) no-repeat;
      transition: opacity 0.3s ease-in-out;
      grid-template-areas:
        "header header"
        "sidebar main";
    }

    @media screen and (max-width: 600px) {
      #main[data-state="open"] { width: calc(100% - 20px); }
    }
    @keyframes fade { from { opacity: 0 } 50% { opacity: .5 } }
    """#

    static let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Demo &amp; test</title>
      <style>
        body { color: red; }
        /* css comment */
      </style>
      <script type="module">
        import x from './x.js';
        /* js block
           comment */
        const y = `template`;
      </script>
      <script type="application/json">{"a": 1}</script>
    </head>
    <body class="main"
          data-value='multi
          line'>
      <!-- a comment
           over lines -->
      <p>Hello <b>world</b>&nbsp;!</p>
      <img src="a.png" alt="x" />
    </body>
    </html>
    """#

    static let xml = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <!-- comment -->
      <key>CFBundleName</key>
      <string>SheepText &amp; co</string>
      <ns:item xmlns:ns="urn:x" ns:attr="1"/>
      <script><![CDATA[
        if (a < b) { }
      ]]></script>
    </dict>
    </plist>
    """#

    static let markdown = #"""
    ---
    title: Front matter
    tags: [a, b]
    ---

    # Heading with `code`

    Setext heading
    ==============

    Some *emphasis*, **strong**, `code`, [a link](https://example.com "title") and
    ![image](img.png). Visit https://sheep.text or <https://auto.link>. Escaped \*star\*.

    - item one
    - [ ] task
      1. nested ordered

         indented code inside the list? no, a paragraph

    > A quote with **bold**
    > ```swift
    > let quoted = true
    > ```

    ```swift
    /* a comment that
       spans lines */
    let x = "fenced"
    ```

    ~~~python
    def f(): pass
    ~~~

    ```
    untagged fence
    ```

        indented code block

    <div class="raw">
    <b>html block</b>
    </div>

    | Col | Other |
    | --- | :---: |
    | a   | b     |

    [ref]: https://example.com "Ref title"

    ---
    Final paragraph with <span>inline html</span> and _underscore emphasis_.
    """#

    static let dockerfile = #"""
    # syntax=docker/dockerfile:1
    FROM --platform=$BUILDPLATFORM golang:1.22 AS build
    ARG VERSION=1.0
    ENV PATH="/app/bin:${PATH}" \
        MODE=release
    WORKDIR /src
    COPY --chown=app:app . .
    # A comment
    RUN --mount=type=cache,target=/root/.cache \
        go build -o /out/app ./cmd/app && \
        echo "built $VERSION"
    RUN <<EOF
    set -e
    echo "heredoc"
    EOF
    EXPOSE 8080/tcp
    HEALTHCHECK --interval=30s CMD curl -f http://localhost/ || exit 1
    ENTRYPOINT ["/out/app", "--serve"]
    CMD echo "shell form"
    """#

    static let sql = #"""
    -- Create the table
    CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL DEFAULT 'anon',
        "quoted col" INTEGER,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
    );
    /* block
       comment */
    SELECT u.id, COUNT(*) AS total, 'it''s' AS s
    FROM users u
    LEFT JOIN orders o ON o.user_id = u.id
    WHERE u.name LIKE :pattern AND u.id > $1 OR u.active = TRUE
    GROUP BY u.id
    HAVING COUNT(*) > 10
    ORDER BY total DESC NULLS LAST;
    CREATE FUNCTION f() RETURNS int AS $$
      SELECT 1;
    $$ LANGUAGE sql;
    """#

    static let diff = #"""
    commit 3f2a1b4c5d6e7f8091a2b3c4d5e6f708192a3b4c
    Author: Someone <someone@example.com>
    Date:   Sat Sep 27 10:00:00 2026 +0700

        Fix the thing

    diff --git a/file.txt b/file.txt
    index 83db48f..bf269f4 100644
    --- a/file.txt
    +++ b/file.txt
    @@ -1,5 +1,5 @@ func context()
     context line
    --- removed line that looks like a header
    +++ added line that looks like a header
     more context
    -old
    +new
    \ No newline at end of file
    @@ -10 +10,2 @@
    -x
    +y
    +z
    """#

    static let log = #"""
    2026-09-27 10:11:12.345Z ERROR [main] Connection failed to 10.0.0.1/24
    2026-09-27T10:11:13+07:00 WARN disk usage high on eth0/1
    Sep 27 10:11:14 switch1 %LINK-3-UPDOWN: Interface GigabitEthernet1/0/1, changed state to down
    10:11:15 INFO vlan 306 enabled, mac aabb.ccdd.eeff learned on Gi1/0/2
    router# show ip route
    ipv6 fe80::1/64 is up, ok
    download completed: success (errors: 0)
    """#
}
