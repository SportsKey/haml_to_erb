# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `-#` HAML comments convert to ERB comments (kaorukobo, upstream PR #3)
- HTML comment blocks (`/` with nested content), conditional comments (`/[if IE]`) and
  revealed conditional comments (`/![if IE]`) convert with their children instead of
  collapsing to an empty `<!-- -->`
- `**opts` in attribute braces and a bare `%div{ attrs }` expression expand at render
  time through `tag.attributes(**(...))` instead of being dropped
- `data: some_hash` / `aria: some_hash` expand through `tag.attributes(data: ...)`
  instead of becoming a literal `data="..."` attribute
- A spec file pinning conversions to hamlit's rendering (`converter_hamlit_parity_spec.rb`)

### Changed

- Generated ERB now relies on Rails' `class_names` and `tag.attributes` helpers (Rails >= 7.0)
  whenever an attribute value is not a literal
- `:ruby` filters emit one `<% ... %>` block with newlines preserved, so multi-line
  statements and trailing comments survive
- `true` renders as a bare attribute for boolean attributes and data-*/aria-*, and as the
  string `"true"` for any other attribute (`draggable="true"`); `false` is omitted inside
  data/aria hashes. Both match hamlit
- Top-level attribute keys keep underscores (`stroke_width` stays `stroke_width`);
  only keys inside data/aria hashes are hyphenated, matching hamlit

### Fixed

- Dynamic `class:` values that can be nil, false or an Array no longer render as the
  literal text `false` / `[]`; they go through `class_names`
- `!=` (and `%tag!= ...`) now emits `<%==` instead of escaping the output
- Nested data/aria values that can be nil or false (ternaries, `&&`/`||`, `&.`, `.presence`)
  are omitted in that case instead of rendering an empty or `"false"` attribute
- Nested data/aria values that are predicate calls (`new_record?`, `!x`) render as a bare
  attribute when true and nothing when false, like hamlit
- A class carried inside a spread hash (`**opts`, `%div{ attrs }`) merges with the tag's
  classes instead of producing a second, ignored `class` attribute
- Two conditional boolean attributes on one tag no longer overwrite each other
- A literal `%>` inside a `-#` comment no longer closes the ERB comment early, and blank
  lines inside a multi-line `-#` block stay blank
- An empty `:ruby` filter no longer raises
- Escape sequences in interpolated string literals decode correctly, so non-ASCII text
  is no longer emitted as `\uXXXX` (kaorukobo, upstream PR #5)
- Quoted attribute keys containing a colon keep their value (kaorukobo, upstream PR #6)
- CI matrix fixed (kaorukobo, upstream PR #4)

## [0.1.0] - 2026-02-06

### Added

- Core conversion engine: HAML string → AST → ERB via `HamlToErb.convert`
- File and directory conversion with `convert_file` and `convert_directory`
- CLI tool `haml_to_erb` with `--check`, `--dry-run`, `--delete`, `--force`, `--version`, and `--debug` flags
- ERB validation via Herb parser (`validate`, `convert_and_validate`)
- Support for tags, attributes, Ruby code blocks, filters, and interpolation
- Static attribute inlining via Prism parser
- Boolean and ARIA/data attribute handling
- Haml 5, 6, and 7 compatibility
- GitHub Actions CI workflow

### Fixed

- Consistent HTML escaping for static attributes
- Odd-backslash logic for escaped quotes in interpolation
- Guard against missing line on HAML syntax errors
- CLI handles missing path argument gracefully
- CLI resolves paths with `File.expand_path`
- Warning when void elements have inline content or nested children
- Raise on unclosed string interpolation
- Safety measures for `--delete` flag (requires `--force` to skip confirmation)
