## Comments

- The gold standard is NO comments. A change that adds a comment should be treated as incomplete, not finished.
- Comments are a code smell: if code needs a comment to be understood, that's a signal to refactor, not a green light to explain.
- Don't write comments — not short ones, not long ones, not "just this once" ones.
- Before writing a comment, exhaust these first:
    - Extract a function with a name that states what it does.
    - Rename a variable so its purpose is obvious.
    - Split a complex conditional into named boolean variables or a named function.
    - Add a test that demonstrates and locks in the behavior.
- If you still believe a comment is unavoidable, stop and treat that as a signal you haven't finished refactoring — go one more round before accepting the comment.
- Never write comments that reference other code, restate what the code already says, mark sections, or narrate history ("changed this because...", "TODO", "NOTE:").
- The only sanctioned exception: a one-line pointer to the ADR that governs a non-obvious decision, e.g. `// ADR-XXXX`. This is allowed only when:
    - the constraint truly can't be made obvious by naming or structure alone, and
    - an ADR actually exists for it — writing this comment is not a substitute for writing the ADR.
- Never restate an ADR's reasoning inline. The comment is a pointer, not a summary — the "why" lives in the ADR, not in the code.
- If you're about to explain *why* the code does something, that reasoning belongs in an ADR (if it's a real decision with alternatives) or a test name (if it's a behavior). Comments are for neither.
