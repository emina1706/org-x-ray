# Org X-Ray by Virago

A free, read-only health check that runs inside a Salesforce org and gives it a score out of 100.
Nothing is changed and no data leaves the org.

## What it checks

| Check | How |
|---|---|
| Licenses nobody uses | Active standard users created more than 90 days ago with no login in 90 days, grouped by license type. Integration and agent licenses are left out. Multiplied by the monthly price you type in for each license type, per year. Not judged in a sandbox, because people rarely log in there. |
| Old automation | Active Process Builders (`FlowDefinitionView`, ProcessType `Workflow` / `InvocableProcess`), objects with more than one active trigger, Apex classes on API versions below 45. Managed package items are skipped. |
| Lead sources that went quiet | Leads grouped by Lead Source over the last 60 days and the last 7 days. **Gone quiet** = a source averaging at least one lead every two days has been silent for 3× its usual gap and at least 48 hours. **Dropping** = a source with 1+ lead a day whose last 7 days are under 40% of its usual rate. |
| Admin access | Active users with Modify All Data (and how they got it: profile or permission set), plus a count of View All Data. |
| Duplicate rules | Active duplicate rules on Account, Contact and Lead. |
| Storage and API use | Data storage, file storage and daily API requests against the org's limits. |
| Failed background jobs | Apex jobs that failed in the last 7 days, grouped by class. |
| Forgotten records | Open opportunities past their close date, accounts and open leads owned by inactive users, reports not run in a year. |
| Security | Users with Manage Users or Author Apex, guest profile write permissions, failed logins among the latest 2,000 logins in the last 7 days. |
| Data quality | Contacts without an email, accounts without a contact, contacts and accounts untouched for two years. |

The results page opens with **Fix these first**: the five findings that add the most to the score for the least effort, each with what to do about it. There is also a PDF report, and CSV downloads of the unused licenses and unused fields.
| Unused fields | Custom fields on Account, Contact, Lead, Opportunity, Case and the 10 largest custom objects that are filled in under 5% of the latest 2,000 records. Formula, auto-number, long text, managed package and inaccessible fields are skipped. Objects with fewer than 20 records are not judged. |

Every check is a separate Apex call, so one failing check never stops the others. Errors are shown in their own section, and the score is marked as incomplete.

## Install in a sandbox or Developer org

You need the Salesforce CLI (`sf`).

```bash
sf org login web --alias xray-test            # use --instance-url https://test.salesforce.com for a sandbox
sf project deploy start --source-dir force-app --target-org xray-test
sf org assign permset --name Org_X_Ray --target-org xray-test
sf org open --target-org xray-test
```

Then open the App Launcher, search for **Org X-Ray**, and click **Run the X-Ray**. Run it as a System Administrator for complete results.

To deploy to a production org, run the tests too:

```bash
sf project deploy start --source-dir force-app --target-org client-prod --test-level RunSpecifiedTests --tests OrgXRayControllerTest
```

The tests create no records, so triggers, validation rules and required fields in the target org cannot make them fail.

## Give clients a one-click install link (unlocked package)

Needs a Dev Hub org (any production org or Developer Edition with Dev Hub turned on).

```bash
sf package create --name "Org X-Ray" --package-type Unlocked --path force-app --no-namespace --target-dev-hub devhub
sf package version create --package "Org X-Ray" --installation-key-bypass --code-coverage --wait 30 --target-dev-hub devhub
sf package version promote --package "Org X-Ray@0.1.0-1" --target-dev-hub devhub
```

The version create command prints a package version id starting with `04t`. The install link is:

```
https://login.salesforce.com/packaging/installPackage.apexp?p0=04t...
```

(use `test.salesforce.com` for sandboxes). Before promoting, add a `versionName` and `versionNumber` to `sfdx-project.json` if the CLI asks for them.

## Settings

In `lwc/orgXRay/orgXRay.js`:

- `BOOKING_URL`: where the "Book a free call" button goes
- `FIELD_OBJECTS`: which objects are scanned for unused fields
- `SAMPLE_SIZE`: how many of the latest records are sampled per object
- `MIN_FIELD_AGE_DAYS`: fields changed more recently than this are not judged
- `INACTIVE_DAYS`: what counts as an unused license

## Known limits (v0.1)

- Workflow Rules and Flow fault paths need the Tooling API, so they are not checked yet.
- Multi-factor authentication is not checked, because the org does not share per-user MFA status with Apex.
- CSV downloads hold up to 200 users and the 50 least used fields per object.
- Fields changed in the last 90 days are not judged, because they are too new. Salesforce only shows the last change date here, so an older field that was edited recently is skipped too.
- The PDF report runs every check again in one go. In very wide orgs it can leave out some field sections to stay within Salesforce limits, and says so.
- Lead flow uses aggregate queries over 60 days. Orgs creating more than ~50,000 leads in 60 days will see an error in that one section.
- Field usage is a sample of the latest records, so a field used only on old records can show as unused. Always check before deleting.
- Brand fonts (Fraunces, DM Sans) fall back to Georgia and the Salesforce font unless they are added as a static resource.

## Files

```
force-app/main/default/
  classes/OrgXRayController.cls        all checks, read-only, returns JSON
  classes/OrgXRayControllerTest.cls    tests
  classes/OrgXRayReportController.cls  lays the checks out for the PDF report
  classes/OrgXRayReportControllerTest.cls  tests
  pages/OrgXRayReport.page             the PDF report
  classes/OrgXRayExportController.cls  builds the CSV downloads
  classes/OrgXRayExportControllerTest.cls  tests
  pages/OrgXRayExport.page             the CSV downloads
  lwc/orgXRay/                         the dashboard
  tabs/Org_X_Ray.tab-meta.xml          the Org X-Ray tab
  permissionsets/Org_X_Ray...xml       access to the tab, the PDF report and the Apex classes
```
