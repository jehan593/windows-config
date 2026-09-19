Please review and clean up uncommitted changes only. Check UI strings, code comments, GitHub metadata, tags, and documentation according to the following guidelines. Do not review or modify anything that is already committed.
---

### General Writing Style
* **Tone:** Keep all text short, simple, straightforward, relevant, and accessible to non-technical users.
* **Clarity over Jargon:** Avoid overly technical terms, internal logic names, or unnecessary engineering jargon across user-facing text and documentation.

---

### Scope of Review & Cleanup

1. **UI Text & Labels (App UI)**
   * Review all user-visible strings, toggle descriptions, settings options, and dialog text added or modified in the current uncommitted changes.
   * Rewrite any verbose or technical copy to be clear, concise, and user-friendly (e.g., replace "Disable OS Battery Saver Throttling" with "Ignore Battery Optimization").

2. **Code Comments**
   * Audit only source files included in the current uncommitted changes.
   * Remove redundant, obvious, or outdated comments.
   * Rewrite necessary comments to be short, plain, and direct, explaining *why* something exists rather than describing self-explanatory code.

3. **GitHub Documentation & Metadata**
   * **README.md:** Update or refine only the uncommitted README changes so project summaries, feature lists, and setup steps are simple to read for any developer or user.
   * **Repository Tags & Description:** Review and suggest (or update) only uncommitted changes to repository descriptions and relevant tags/topics. Keep them short, clear, accurate, and free of fluff.

4. **Diff Audit (Since Last Commit)**
   * Perform a full pass across all current uncommitted changes to remove debug code, temporary strings, or leftover placeholders.
