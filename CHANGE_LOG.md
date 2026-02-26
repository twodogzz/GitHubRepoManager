# GitHub Repo Manager - Change Log

## v2.4.6 - 2026-02-26

### Fixed
- Corrected local project scanning to include hidden directories on Windows 10/11 by using `Get-ChildItem -Directory -Force`.
- Fixed `.git` detection for both:
  - standard hidden `.git` directories
  - `.git` pointer files using `gitdir: ...` (worktree/submodule/separate git-dir layouts)
- Fixed rename/identity detection to stop assuming project-local `.git\config` and instead resolve the actual Git metadata path first.
- Fixed backup logic to archive the resolved Git directory target instead of only `<project>/.git`.

### Behavior Updates
- Added a centralized Git metadata resolver (`Resolve-GitMetadataPath`) used by:
  - `Test-GitCorrupted`
  - `Get-RemoteRepoName`
  - `Backup-GitFolder`
- `.git` pointer files with missing/invalid `gitdir` targets are now explicitly classified as corrupted and follow existing restore/repair flow.
- Added explicit runtime logs for:
  - detected `.git` directory
  - detected `.git` pointer file + resolved target
  - invalid `.git` pointer file target classification

### Impact
- Prevents false "no .git" results caused by hidden metadata on Windows.
- Enables reliable handling of non-standard Git layouts without breaking existing M3/restore behavior.
- Reduces incorrect skips during rename detection and improves backup correctness.

---

## **GitHub Repo Manager — v2.4.1 Change Log**

### **1. `.git_backups` added to `$Excluded`**
- Prevents the backup directory from being treated as a project.
- Eliminates false `.git` corruption warnings.
- Stops the script from trying to create a GitHub repo named `.git_backups`.

**Impact:** Cleaner runs, no noise, no accidental repo creation.

---

## **2. `.git` backup/restore now runs *only* when `.git` actually exists**
- Added guard:  
  `if (-not (Test-Path (Join-Path $ProjectPath ".git"))) { continue }`
- Prevents backup logic from running on non‑repo folders.
- Eliminates dozens of “Could not find item …\.git” errors.

**Impact:** Backup system is now stable, quiet, and accurate.

---

## **3. Intelligent rename detector now works reliably**
- Previously skipped because `.git` was incorrectly treated as missing.
- Now only runs on valid Git repos.
- Correctly detects mismatches like:  
  `Swimming-Pool_Manager → Swimming_Pool_Manager`
- Triggers the **Ultra‑safe rename prompt**.

**Impact:** Rename detection is now predictable and trustworthy.

---

## **4. Fixed `.ToArray()` bug**
- `$LocalProjects` sometimes collapsed to a string when only one folder existed.
- Forced array semantics:  
  `$LocalProjects = @($LocalProjects)`

**Impact:** No more “String does not contain method ToArray” errors.

---

## **5. Improved project scanning stability**
- Excluded folders are now filtered early.
- Only valid Git repos participate in:
  - rename detection  
  - backup/restore  
  - identity extraction  

**Impact:** Faster, cleaner, more accurate scanning.

---

## **6. `.git` corruption detection now behaves correctly**
- No longer flags non‑repo folders as corrupted.
- Only checks `.git` when `.git` exists.
- Integrates cleanly with backup/restore.

**Impact:** Corruption warnings now mean something real.

---

## **7. Intelligent rename prompt (Option C) fully integrated**
Ultra‑safe prompt includes:

- Local folder name  
- GitHub repo name  
- Warnings about consequences  
- Options to rename GitHub, rename folder, or skip  

**Impact:** Maximum safety, maximum clarity, zero guessing.

---

## **8. Remote and local sets rebuilt after rename operations**
- Ensures downstream logic (create, orphan, archive) uses updated names.
- Prevents stale state issues.

**Impact:** Script remains consistent after rename decisions.

---

## **9. Orphan detection now runs *after* rename detection**
- Prevents false orphan classification.
- Ensures rename logic always gets first priority.

**Impact:** Correct classification of rename vs orphan scenarios.

---

## **10. Full script formatting cleanup**
- Removed redundant checks.
- Improved readability.
- Ensured consistent indentation and structure.

**Impact:** Easier maintenance and future enhancements.

---

## **Summary of v2.4.1**
This release stabilizes the intelligent rename system, fixes `.git` detection, eliminates noisy errors, and ensures the Repo Manager behaves predictably and safely across all project states.

It is now:

- **Safer**  
- **Quieter**  
- **More accurate**  
- **More resilient**  
- **More predictable**  
- **Ready for GUI layering later**

---