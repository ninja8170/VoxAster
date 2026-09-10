OmniVoice Native 3.4.5 — Project Isolation Fix

Fixes the project ownership bug discovered in 3.4.4.

Projects are now genuinely isolated from global History:
- New Project starts with its own empty output-ID set.
- Saving a new project no longer attaches every previous History item.
- Each project stores only output IDs created while that project is active.
- Opening a saved project restores only that project's output set.
- Generating Voice Clone, Voice Design or Long Form audio while a project is
  active automatically associates the new generation with that project.
- Saved/open projects update their output membership immediately.
- Global History remains global and independent.

Existing projects created by older builds may already contain polluted historical
output IDs. They are not automatically rewritten because the app cannot know which
old outputs truly belonged to those projects. Delete/recreate those test projects
if you want a clean project library.

Install:
  cd ~/Downloads/OmniVoice-Native-3.4.5-Project-Isolation-Fix
  chmod +x install.command
  ./install.command
