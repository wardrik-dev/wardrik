# Writing the docs

Readers skim for the point, then read the part they need. Write for that. This covers the site,
the package guides and READMEs, and the docs in the code.

## Every page

- **Open with the point.** One sentence on what the page is for, then the smallest example that
  works.
- **Main path first.** Put what most readers do first. Move exceptions, limits and edge cases to a
  `## Details` section at the end, or to the reference page, and link to it.
- **One idea per paragraph.** Three sentences at most.
- **One condition per sentence.** Split "where…, unless…, and…" into separate sentences, or a list.
- **Headings tell the story.** Read alone, the headings should summarise the page.
- **Talk to the reader.** Guides and examples walk through with "let's" and "we". Everywhere else,
  say "you". Active voice. Name the thing the reader types or sees.
- **Show, then tell.** An example before the explanation of it.
- **Link, don't repeat.** A fact lives in one place; other pages link to it.

## Where a fact lives

| Fact | Home |
| --- | --- |
| How to do a task | A site guide |
| Every option, field and error | The reference, generated from the package guides and option schemas |
| What a module is for and how to call it | Its `@moduledoc` and `@doc`s |
| Why the code is the way it is | A comment, only where the code can't say it |

## Each kind of page

| Kind | Shape |
| --- | --- |
| Get started | Numbered steps that end with something working. |
| Concept | What it is, why it matters, how it works, with a diagram or table where it helps. Details last. |
| Guide (Build, Run) | A task: what you'll do, then steps. Options and limits in Details or the reference. |
| Example | What it does, what it takes, the files, how to try it, what it shows. |
| Reference | Generated from the code. Complete, in tables. The only place for every option. |

A concept with several topics a reader looks up on their own gets a group: an overview page, then a
page per topic. Policy is the model: Policy, Approvals, Content from outside, Budgets, Judged calls.

## Docs in the code

Hexdocs is for people who call Wardrik or extend it. Each module is one of three kinds:

| Kind | What it is | Its docs |
| --- | --- | --- |
| API | What an app calls or gets back: `Wardrik`, its structs, `Wardrik.Listener` | A summary sentence, an example, then only what a caller must know. About 200 words. |
| Extension point | What a package implements: `Wardrik.Tool`, `Wardrik.Hook`, `Wardrik.Runtime` | A summary, an example implementation, the callbacks. About 150 words. |
| Internal | Everything else | `@moduledoc false`. A comment only for a why the code can't show. |

- **A `@doc` opens with what the function returns or does**, in one sentence. Options come from
  the NimbleOptions schema; don't retype them. One example. About 60 words.
- **Keep the contract, cut the mechanism.** Say what a caller can rely on: ordering, what survives
  a crash, what blocks, the errors, who may call it. Leave out which process does what.
- **Define every value in an example**, unless it's a module of the reader's own.
- **One line is fine.** A summary sentence is a whole moduledoc when the functions say the rest.

The word counts are a guide, not a check.

## Voice

Write the way one developer explains something to another.

- **Start from the reader's itch.** One sentence on why they're here, then code.
- **Code first, then "Notice…"** to point at the line that matters.
- **Name a new term in one line**, then "In other words, …" if the definition is dense.
- **End with when to reach for it**, and when not to.
- **Recap a long guide**: "To recap, we've: …"
- **Plain opinions.** "Do X." beats "You may want to consider X."
- **Casual is fine; jokes are rare**, and never in reference.
- **Short sentences.** Split "X, it does Y" into two.

## Words

- Prefer short, common words: "use", not "make use of".
- Cut qualifiers that only an implementer needs; the reference has them.
- Keep terms steady: a *call* waits, a *person* decides, an *agent* runs *turns*.
- No marketing adjectives. Show what it does instead.

## Before you finish

- Does the first paragraph say what the page is for?
- Could a reader stop after the first section and have done the common thing?
- Is every fact you cut still somewhere, linked from here?
