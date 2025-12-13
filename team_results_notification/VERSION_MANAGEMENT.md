# Version Management Guide

This document explains how to manage app versions for the PWA (Progressive Web App) update system.

## Overview

The app uses three different version numbers that serve different purposes:

1. **`pubspec.yaml`** - The actual app version (compiled into the app)
2. **`main.py`** - The target version the backend expects clients to have
3. **`sw.js`** - Service worker cache version (for cache management)

## How Version Checking Works

```
┌─────────────────┐
│  pubspec.yaml   │  →  Compiled into app  →  PackageInfo.fromPlatform()
│  version: 1.0.0+1│                                    │
└─────────────────┘                                    │
                                                       │
                                                       ▼
                                              ┌─────────────────┐
                                              │  Compare with   │
                                              │                 │
┌─────────────────┐                          │  main.py        │
│  main.py        │  →  API Response  →      │  version: 1.0.0  │
│  build: "1"     │                          │  build: "1"      │
└─────────────────┘                          └─────────────────┘
                                                       │
                                                       ▼
                                              ┌─────────────────┐
                                              │  If different:  │
                                              │  Auto-Update    │
                                              │  (Silent)       │
                                              └─────────────────┘
                                                       │
                                                       ▼
                                              ┌─────────────────┐
                                              │  Clear Cache    │
                                              │  Reload App     │
                                              └─────────────────┘
```

**Update Behavior**: The app now uses **automatic silent updates**. When a version mismatch is detected:
- ✅ Update happens automatically in the background
- ✅ No notification popup is shown
- ✅ Cache is cleared and app reloads immediately
- ✅ Process completes in ~2-3 seconds

### How Old Apps Recognize Their Version

**Important**: When a user has an old cached version of the app, the old JavaScript code runs with **hardcoded fallback version constants**.

**For Web/PWA:**
- The old app's JavaScript has the old version hardcoded in `login_page.dart`:
  ```dart
  static const String _fallbackVersion = '1.0.0';  // Old version
  static const String _fallbackBuild = '1';         // Old build
  ```
- When the old app checks the backend, it compares its **hardcoded old version** with the backend's new version
- If they differ → Update notification appears ✅

**For Native Apps:**
- The old app reads its version from `PackageInfo.fromPlatform()` (from the installed app package)
- This version comes from the `pubspec.yaml` that was used when the app was built
- The old app compares this with the backend version

**Key Point**: `CACHE_VERSION` in `sw.js` is **NOT used** for version comparison. It's only for cache invalidation. The version comparison uses:
- For web: Hardcoded fallback constants in the deployed JavaScript
- For native: `PackageInfo.fromPlatform()` from the installed app

**Example Scenario:**
1. User has old app cached (version `1.0.0+1` with old JavaScript)
2. You deploy new version (`1.0.0+2`) and update backend to `1.0.0+2`
3. Old app's JavaScript (with hardcoded `1.0.0+1`) runs
4. Old app checks backend → Gets `1.0.0+2`
5. Comparison: `"1.0.0+2" != "1.0.0+1"` → **Automatic update triggered** ✅
6. Cache cleared, app reloads silently with new version

## File Locations

- **App Version**: `pubspec.yaml` (line ~19)
- **Backend Version**: `backend_fastapi/main.py` (around line 3904-3907)
- **Service Worker Cache**: `web/sw.js` (line 3)

## Workflow Scenarios

### Scenario 1: New App Version Release (Recommended)

**When to use**: When you've made code changes, bug fixes, or new features that require users to update.

**Steps**:

1. **Update `pubspec.yaml`**:
   ```yaml
   version: 1.0.0+2  # Increment build number (+1, +2, +3, etc.)
   ```

2. **Update `backend_fastapi/main.py`**:
   ```python
   @app.get("/api/app/version")
   async def get_app_version():
       return {
           "version": "1.0.0",  # Keep same unless major/minor version change
           "build": "2"  # Must match the number after + in pubspec.yaml
       }
   ```

3. **Update `web/sw.js`** (Recommended):
   ```javascript
   const CACHE_VERSION = 'v4';  // Increment: v3 → v4 → v5, etc.
   ```

4. **Rebuild the app**:
   ```bash
   flutter build web --release
   ```

5. **Restart your backend server** (if needed)

6. **Deploy the new build**

**Result**: 
- Users with old version (1.0.0+1) will **automatically receive the update**
- Update happens silently in the background (no notification popup)
- Cache is cleared and app reloads automatically (~2-3 seconds)
- Users will see the new version (1.0.0+2) after reload

---

### Scenario 2: Cache Fix Only (No Version Change)

**When to use**: When you need to fix caching issues, update service worker logic, or force cache refresh without changing app code.

**Steps**:

1. **Update `web/sw.js` only**:
   ```javascript
   const CACHE_VERSION = 'v4';  // Increment cache version
   ```

2. **Do NOT change** `pubspec.yaml` or `main.py`

3. **Rebuild the app**:
   ```bash
   flutter build web --release
   ```

4. **Deploy the new build**

**Result**:
- **No automatic update will be triggered** (because app version hasn't changed)
- All users will get the new service worker on next page load
- Old caches will be cleared and new cache created
- Useful for fixing cache-related issues

**Important Note**: 
- `CACHE_VERSION` is **separate** from app version comparison
- Updating `CACHE_VERSION` alone will **NOT** trigger automatic updates
- Automatic updates only occur when `pubspec.yaml` version ≠ `main.py` version
- `CACHE_VERSION` only affects service worker cache invalidation, not version detection

---

### Scenario 3: Major/Minor Version Change

**When to use**: When you want to change the semantic version (1.0.0 → 1.1.0 or 2.0.0).

**Steps**:

1. **Update `pubspec.yaml`**:
   ```yaml
   version: 1.1.0+1  # Changed minor version, reset build number
   ```

2. **Update `backend_fastapi/main.py`**:
   ```python
   return {
       "version": "1.1.0",  # Match the version part
       "build": "1"  # Match the build number
   }
   ```

3. **Update `web/sw.js`**:
   ```javascript
   const CACHE_VERSION = 'v4';
   ```

4. **Rebuild and deploy**

---

## Version Number Format

### `pubspec.yaml`
```yaml
version: MAJOR.MINOR.PATCH+BUILD
```
- **MAJOR.MINOR.PATCH**: Semantic version (e.g., 1.0.0, 1.1.0, 2.0.0)
- **BUILD**: Build number (1, 2, 3, ...) - increments with each release

**Examples**:
- `1.0.0+1` → First release
- `1.0.0+2` → Second build (bug fix)
- `1.1.0+1` → Minor version update
- `2.0.0+1` → Major version update

### `main.py`
```python
{
    "version": "1.0.0",  # Semantic version (MAJOR.MINOR.PATCH)
    "build": "2"        # Build number (as string)
}
```

**Important**: The `build` number in `main.py` must match the number after `+` in `pubspec.yaml`.

### `sw.js`
```javascript
const CACHE_VERSION = 'v3';  // Simple increment: v1, v2, v3, v4, ...
```

**Note**: This doesn't need to match app version. It's just for cache management.

---

## Quick Reference Table

| Change Type | pubspec.yaml | main.py | sw.js | Auto-Update? |
|------------|--------------|---------|-------|--------------|
| New app version | ✅ Change | ✅ Change | ✅ Change | ✅ Yes (Silent) |
| Cache fix only | ❌ No change | ❌ No change | ✅ Change | ❌ No |
| Major/minor version | ✅ Change | ✅ Change | ✅ Change | ✅ Yes (Silent) |

---

## Troubleshooting

### Problem: App keeps auto-updating in a loop

**Cause**: `pubspec.yaml` and `main.py` versions don't match, or update flags aren't being cleared properly.

**Solution**: 
1. Check both files have the same version and build number
2. Rebuild the app
3. Clear browser cache manually if needed
4. Check browser console for update-related logs

### Problem: Users not getting automatic updates on mobile

**Cause**: Aggressive mobile browser caching or service worker not updating.

**Solution**:
1. Ensure `sw.js` cache version is incremented
2. The automatic update mechanism should clear caches and reload
3. Check that backend version matches `pubspec.yaml` version
4. If still not working, users may need to:
   - Close the app completely
   - Clear browser cache manually
   - Reopen the app (update should trigger automatically)

### Problem: Service worker not updating

**Cause**: Service worker file itself is cached.

**Solution**:
1. Increment `CACHE_VERSION` in `sw.js`
2. Ensure `index.html` has `updateViaCache: 'none'` (already configured)
3. Rebuild and redeploy

---

## Best Practices

1. **Always increment build number** for each release (even small fixes)
2. **Keep `pubspec.yaml` and `main.py` in sync** - they must match
3. **Increment `sw.js` cache version** with each rebuild to ensure cache refresh
4. **Test automatic update flow** on both desktop and mobile before deploying
5. **Document version changes** in your release notes
6. **Monitor update logs** in browser console to verify automatic updates are working

## Update Mechanism Details

### Automatic Silent Updates

The app uses an **automatic silent update mechanism** that:

- ✅ **Detects version mismatches** automatically on app load and periodically
- ✅ **Updates silently** without showing notification popups
- ✅ **Clears all caches** (localStorage, sessionStorage, service worker caches)
- ✅ **Unregisters old service workers** to ensure clean update
- ✅ **Reloads the app** with cache-busting parameters
- ✅ **Verifies update** after ~2 seconds to confirm new version is loaded
- ✅ **Completes in ~2-3 seconds** total

### Update Process Flow

1. **Version Check**: App compares its version with backend version
2. **Mismatch Detected**: If versions differ, `_handleUpdateSilently()` is called
3. **Cache Clearing**: All browser storage and caches are cleared
4. **Service Worker**: Old service workers are unregistered
5. **Reload**: Page reloads with cache-busting query parameters
6. **Verification**: After 2 seconds, version is checked again
7. **Completion**: If version matches, update flags are cleared

### Update Suppression

To prevent update loops, the app suppresses update checks for:
- **5 seconds** after an update starts
- **2 seconds** after page reload (to allow new version to load)
- Update flags are cleared after successful version verification

### Technical Implementation

- **Method**: `_handleUpdateSilently()` - Handles automatic updates without UI
- **Method**: `_deleteAllCachesAndReload()` - Aggressively clears all caches and reloads
- **Method**: `_checkIfUpdateReload()` - Verifies update after reload
- **State**: `updating_app` and `update_started_at` flags prevent update loops

---

## Example: Complete Release Workflow

```bash
# 1. Update version in pubspec.yaml
# version: 1.0.0+2

# 2. Update version in main.py
# "build": "2"

# 3. Update cache version in sw.js
# const CACHE_VERSION = 'v4';

# 4. Rebuild
flutter build web --release

# 5. Deploy to server
# (your deployment command here)

# 6. Restart backend (if needed)
# (your restart command here)
```

---

## Version History Template

Keep track of your versions:

```
v1.0.0+1 (2024-01-15)
- Initial release
- sw.js v1

v1.0.0+2 (2024-01-20)
- Fixed login bug
- Improved cache handling
- sw.js v2

v1.1.0+1 (2024-02-01)
- Added new feature X
- sw.js v3
```

---

## Questions?

If you're unsure which version to change:
- **App code changed?** → Update `pubspec.yaml` and `main.py`
- **Only cache/service worker changed?** → Update `sw.js` only
- **Both changed?** → Update all three

Remember: **When in doubt, update all three to be safe!**

