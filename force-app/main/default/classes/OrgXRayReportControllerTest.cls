/**
 * No records are inserted, so a customer's triggers and validation rules cannot fail these tests.
 * The section builders are given check results as JSON.
 */
@IsTest
private class OrgXRayReportControllerTest {

    private static String ok(String data) {
        return '{"key":"test","ok":true,"data":' + data + '}';
    }

    private static List<String> rowNames(OrgXRayReportController.Section s) {
        List<String> names = new List<String>();
        for (OrgXRayReportController.Row r : s.rows) {
            names.add(r.name);
        }
        return names;
    }

    @IsTest
    static void pageBuildsEverySection() {
        PageReference page = Page.OrgXRayReport;
        page.getParameters().putAll(new Map<String, String>{
            'score' => '57', 'tier' => 'Messy but fixable', 'waste' => '$1,000',
            'sample' => '100', 'minAge' => '90', 'objects' => 'Account,Not_A_Real_Object__c'
        });
        Test.setCurrentPage(page);

        OrgXRayReportController report = new OrgXRayReportController();

        Assert.areEqual('57', report.score);
        Assert.areEqual('Messy but fixable', report.tier);
        Assert.areEqual(12, report.sections.size());
        Assert.isTrue(report.failedCount >= 1, 'The unknown object should count as a failed check');
    }

    @IsTest
    static void pageWorksWithoutParameters() {
        Test.setCurrentPage(Page.OrgXRayReport);

        OrgXRayReportController report = new OrgXRayReportController();

        Assert.areEqual(10, report.sections.size());
        Assert.isNull(report.score);
        Assert.isFalse(report.hasFixFirst);
    }

    @IsTest
    static void fixFirstReadsTheDashboardList() {
        List<OrgXRayReportController.FixItem> items = OrgXRayReportController.parseFixFirst(
            '[{"title":"Remove admins","effort":"Quick","how":"Check each one."}]');
        Assert.areEqual(1, items.size());
        Assert.areEqual('Quick', items[0].effort);
        Assert.isTrue(OrgXRayReportController.parseFixFirst('not json').isEmpty());
    }

    @IsTest
    static void securityLeavesOutCountsThatCouldNotRun() {
        OrgXRayReportController.Section s = OrgXRayReportController.security(ok('{"manageUsersCount":3,'
            + '"authorApexCount":null,"guestWriteCount":0,"failedLogins":2,"loginsSampled":50}'));
        Assert.areEqual(3, s.rows.size());
    }

    @IsTest
    static void dataQualityShowsShares() {
        OrgXRayReportController.Section s = OrgXRayReportController.dataQuality(ok('{"contactsNoEmail":5,'
            + '"contactsStale":0,"contactsTotal":10,"accountsNoContact":null,"accountsStale":1,"accountsTotal":4}'));
        Assert.areEqual(3, s.rows.size());
        Assert.areEqual('5 of 10', s.rows[0].detail);
    }

    @IsTest
    static void failedCheckShowsItsError() {
        OrgXRayReportController.Section s = OrgXRayReportController.jobs(
            '{"key":"jobs","ok":false,"error":"Query failed","data":{}}');
        Assert.areEqual('Query failed', s.error);
        Assert.isFalse(s.hasRows);
    }

    @IsTest
    static void licensesListsUsersWithCost() {
        OrgXRayReportController.Section s = OrgXRayReportController.licenses(ok('{"isSandbox":false,'
            + '"inactiveCount":1,"days":90,"users":[{"name":"Ana","license":"Salesforce",'
            + '"lastLogin":"2026-01-15T10:00:00.000+0000"}]}'), '$1,800');
        Assert.isTrue(s.summary.contains('$1,800'));
        Assert.isTrue(s.rows[0].detail.contains('2026-01-15'));
    }

    @IsTest
    static void licensesExplainsSandbox() {
        OrgXRayReportController.Section s = OrgXRayReportController.licenses(
            ok('{"isSandbox":true,"inactiveCount":32,"days":90,"users":[]}'), null);
        Assert.isTrue(s.summary.contains('sandbox'));
        Assert.isFalse(s.hasRows);
    }

    @IsTest
    static void leadFlowListsSources() {
        OrgXRayReportController.Section s = OrgXRayReportController.leadFlow(ok('{"quietCount":1,"droppingCount":0,'
            + '"sources":[{"source":"Web","status":"quiet","perDay":1.0,"last7":0,"lastLead":null}]}'));
        Assert.areEqual('Web', s.rows[0].name);
        Assert.isTrue(OrgXRayReportController.leadFlow(ok('{"skipped":true}')).summary.contains('not available'));
        Assert.isTrue(OrgXRayReportController.leadFlow(ok('{"quietCount":0,"droppingCount":0,"sources":[]}')).summary.contains('No leads'));
    }

    @IsTest
    static void automationListsProcessesAndTriggers() {
        OrgXRayReportController.Section s = OrgXRayReportController.automation(ok('{"apexClassCount":5,'
            + '"oldClassCount":1,"activeTriggers":2,"oldFlowCount":1,"stuckFlowCount":0,'
            + '"legacyProcesses":[{"name":"Old","lastModified":null}],'
            + '"multiTriggerObjects":[{"object":"Account","triggers":["One","Two"]}]}'));
        Assert.areEqual(2, s.rows.size());
        Assert.isTrue(s.rows[1].detail.contains('One, Two'));
    }

    @IsTest
    static void accessListsAdmins() {
        OrgXRayReportController.Section s = OrgXRayReportController.access(ok('{"modifyAllCount":1,"activeUsers":3,'
            + '"viewAllCount":1,"modifyAllUsers":[{"name":"Ana","via":["Profile: Admin","Permission set: Data"]}]}'));
        Assert.isTrue(s.rows[0].detail.contains('Profile: Admin'));
    }

    @IsTest
    static void duplicatesShowsMissingRules() {
        OrgXRayReportController.Section s = OrgXRayReportController.duplicates(
            ok('{"activeRules":{"Lead":0,"Account":2}}'));
        Assert.isTrue(rowNames(s).contains('Lead'));
        Assert.areEqual(2, s.rows.size());
    }

    @IsTest
    static void limitsUseReadableNames() {
        OrgXRayReportController.Section s = OrgXRayReportController.limitsUsed(
            ok('{"limits":[{"name":"DataStorageMB","used":186,"max":200,"pct":93.0}]}'));
        Assert.areEqual('Data storage (MB)', s.rows[0].name);
    }

    @IsTest
    static void jobsNameUnnamedJobs() {
        OrgXRayReportController.Section s = OrgXRayReportController.jobs(
            ok('{"failedCount":3,"jobs":[{"name":null,"count":3}]}'));
        Assert.areEqual('Unnamed job', s.rows[0].name);
    }

    @IsTest
    static void staleDataLeavesOutCountsThatCouldNotRun() {
        OrgXRayReportController.Section s = OrgXRayReportController.staleData(ok('{"oppsPastClose":4,'
            + '"accountsInactiveOwner":null,"leadsInactiveOwner":0,"reportsUnused":9,"reportsTotal":20}'));
        Assert.areEqual(3, s.rows.size());
    }

    @IsTest
    static void fieldsExplainSkippedNewFields() {
        OrgXRayReportController.Section s = OrgXRayReportController.fields('Account', ok('{"sampleSize":100,'
            + '"rarelyUsedCount":1,"scannedFieldCount":5,"neverUsedCount":0,"tooNewCount":2,"minAgeDays":90,'
            + '"rarelyUsed":[{"label":"Rare","apiName":"Rare__c","filledPct":1.0}]}'));
        Assert.isTrue(s.summary.contains('2 changed in the last 90 days'));
        Assert.areEqual('Rare', s.rows[0].name);
    }

    @IsTest
    static void fieldsDoNotJudgeSmallObjects() {
        OrgXRayReportController.Section s = OrgXRayReportController.fields('Account', ok('{"sampleSize":3}'));
        Assert.isTrue(s.summary.contains('too few'));
        Assert.isTrue(OrgXRayReportController.fields('Lead', ok('{"skipped":true}')).summary.contains('Not available'));
    }
}
