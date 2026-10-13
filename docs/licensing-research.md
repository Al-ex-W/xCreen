# xCreen: attribution-oriented software licensing

## Recommendation

Use **unmodified Apache License 2.0 (`Apache-2.0`) plus a short factual `NOTICE` file** identifying xCreen, Alexander Wahlström, and the verified upstream repository. This is the best fit among the compared options for permissive commercial use with preservation of explicit upstream attribution on distributed derivatives: Apache §2 grants royalty-free copyright permissions, §3 supplies a scoped contributor patent grant, and §4(d) expressly addresses attribution notices.[1]

**Important limit:** this gives notice-retention credit, not guaranteed prominent public credit. Apache does not require a fork's homepage, advertisements, splash screen, UI, or store listing to credit the author. Section 4(d) allows a readable notice in distributed NOTICE text, accompanying source/documentation, or the product's normal third-party-notices display. The distributor chooses a compliant location; you cannot force a UI placement simply by writing that demand in NOTICE.[1]

If the real requirement is mandatory visible credit specifically for commercial forks, Apache, MIT, and BSD-3 do not provide that requirement. Do not describe them as doing so, or append an extra mandatory condition while presenting the result as the unchanged standard license.[1][2][3] A separately drafted licensing arrangement would need legal review; this memo does not recommend one or guarantee enforceability.

## Comparison

| Choice | Commercial use and credit obligations | Practical fit |
|---|---|---|
| **Apache-2.0 + NOTICE** | Permits royalty-free use/modification/distribution. Distribution requires a license copy; modified files need prominent change notices; distributed derivative source retains relevant original copyright, patent, trademark, and attribution notices. If upstream includes NOTICE, distributed derivatives carry a readable copy of relevant attribution notices using a §4(d) location. No commercial-only distinction or mandatory visible UI credit.[1] | **Recommended:** explicit mechanism for author + upstream attribution, with a scoped patent grant. More compliance steps than MIT.[1] |
| **MIT** | Explicitly permits selling copies and other unrestricted dealings subject to inclusion of the copyright and permission notice in all copies or substantial portions. Credit is primarily copyright-notice preservation, not a dedicated project-credit or UI-credit requirement.[2] | Good simpler alternative if preserving `Copyright … Alexander Wahlström` is sufficient. No express patent grant in its text; do not overstate that as proof that no patent rights could ever arise.[2] |
| **BSD-3-Clause** | Permits source/binary redistribution with or without modifications. Source retains copyright, conditions, and disclaimer; binary distributions reproduce them in documentation and/or other supplied materials. Author/contributor names cannot be used to endorse or promote derived products without specific written permission.[3] | Reasonable, but the non-endorsement clause prevents implied endorsement rather than requiring publicity. No mandatory UI credit and no express patent grant in the text.[3] |
| **BSD-4-Clause** | Adds: “All advertising materials mentioning features or use of this software” must display the specified acknowledgment; also retains source/binary notice and non-endorsement conditions.[4] | Not recommended. This is an advertising trigger, not a general UI-credit requirement or a rule limited to commercial forks. Acknowledgment obligations accumulate when combining independently credited components; the GNU/FSF discussion documents this burden.[4][6] |
| **Creative Commons licenses** | Creative Commons expressly recommends against applying its licenses to software, citing missing software-specific source-distribution terms, patent considerations, and interoperability issues. It distinguishes suitable uses for documentation and separate artistic assets, and notes CC0 as an exception acceptable for software.[5] | Do not choose CC BY merely to obtain attribution for the code. CC0 would also not provide the desired attribution condition. Consider separate asset/documentation licensing only if appropriate.[5] |

## What Apache compliance actually means for xCreen

1. **Commercial and noncommercial redistribution are treated alike.** There is no special “commercial fork” category in §4.[1]
2. **Distribute the actual license, not just a link.** Section 4(a) requires giving recipients a copy of the license.[1]
3. **Mark changed files.** Section 4(b) requires prominent notices stating that the files were changed.[1]
4. **Retain relevant original notices in distributed derivative source.** Section 4(c) covers copyright, patent, trademark, and attribution notices, but excludes notices not pertaining to any part of the derivative.[1]
5. **Include upstream attribution from NOTICE when distributing derivatives.** Section 4(d) permits the specified alternative locations and excludes notices that no longer pertain. A readable factual upstream URL can form part of this attribution; the license does not independently require a clickable link, inbound backlink, or an advertisement.[1]
6. **NOTICE is informational, not a second license.** The text expressly says its contents do not modify the license. Do not put “commercial users must prominently credit me in their UI” in NOTICE and claim Apache makes it mandatory.[1]
7. **No source-publication requirement.** Apache allows distribution in source or object form and additional/different terms for modifications or derivatives as a whole, while preserving compliance for the licensed work. A commercial fork may therefore remain proprietary subject to those obligations.[1]
8. **No general SaaS credit trigger.** Section 4's redistribution obligations do not create a special requirement to credit an upstream author merely because a private modified server is operated commercially. Distribution of code to users, including browser-delivered code, must be assessed separately; “SaaS” alone does not determine whether redistribution occurs.[1]
9. **Attribution is not endorsement.** Section 6 withholds trademark permissions except customary origin descriptions and NOTICE reproduction; do not suggest Alexander endorses a fork.[1]

## Suggested implementation, not applied to any repository

- Put the complete, unchanged Apache-2.0 text in `LICENSE`.[1]
- Use the official Apache application boilerplate in appropriate source files, filling in the actual copyright year(s) and copyright owner; do not invent dates or ownership.[1]
- Add a short informational `NOTICE`, for example:

```text
xCreen
Copyright [actual year(s)] Alexander Wahlström

This product includes software from xCreen,
originally developed by Alexander Wahlström.
Upstream project: [verified canonical repository URL]
```

This is a proposed factual notice, not a new license condition. Verify authorship/ownership before use. The likely URL `https://github.com/Al-ex-W/xCreen` is context supplied for this task, **not independently confirmed in this research**; replace the placeholder only after confirming the canonical repository. Preserve notices for other contributors and dependencies as applicable rather than claiming the whole combined project as one author's work.

A README explanation can say:

> xCreen is licensed under Apache-2.0. Commercial use and forks are allowed. When redistributing, comply with the license's license-copy, change-notice, and relevant attribution-notice requirements. The upstream NOTICE identifies Alexander Wahlström and xCreen. Visible acknowledgment in your README or About page is appreciated, but is not an additional license condition.

The required/requested distinction in that wording follows Apache §4; visible credit remains a voluntary request.[1]

## Scope and cautions

This is a practical reading of the published license texts, **not legal advice or a guarantee of enforceability**. Ownership, existing contributor grants, third-party dependency licenses, and other applicable rights need checking before a project is relicensed. No repository was inspected or changed.

Official/steward and recognized standards sources were fetched directly. `web_extract` was unavailable under the configured search-only backend; direct HTTPS retrieval succeeded. The first HTML parsing attempt lacked BeautifulSoup; a standard-library parser was used instead. The workspace path was rejected by the terminal tool because of its combining accent, so retrieval/verification ran in the expressly authorized scratch directory, without any repository operation.

## Sources

[1] https://www.apache.org/licenses/LICENSE-2.0
    > "The contents of the NOTICE file are for informational purposes only and do not modify the License."
[2] https://opensource.org/license/mit
    > "The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software."
[3] https://opensource.org/license/bsd-3-clause
    > "Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution."
[4] https://spdx.org/licenses/BSD-4-Clause.html
    > "All advertising materials mentioning features or use of this software must display the following acknowledgement:"
[5] https://creativecommons.org/faq
    > "We recommend against using Creative Commons licenses for software."
[6] https://www.gnu.org/licenses/bsd.html
    > "The result is a plethora of licenses, requiring a plethora of different sentences."
