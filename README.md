
## Azure RBAC PIM Management PowerShell Script

A PowerShell script for administrators to manage Azure RBAC assignments using Privileged Identity Management (PIM).

Features:
- Bulk create/update for PIM assignments using a CSV input file.
- Supports users, groups, and service principals.
- Finds roles and resource scopes through search mechanisms.
- Support for active and eligible PIM assignments in time-bound or permanent forms.
- Supports full/exact matching and partial matching for all inputs.
- Interactively prompts the admin to select the correct information when the input is ambiguous.
- Respects the default Azure PIM policy settings.


Tested with PowerShell 7 and the latest Azure PowerShell modules as of October 2026.
