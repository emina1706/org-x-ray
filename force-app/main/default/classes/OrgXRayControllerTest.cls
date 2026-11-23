/**
 * These tests must pass in any org, so they never insert records: a customer's triggers,
 * validation rules and required fields would fail them. Logic that loops over query results
 * is tested with in-memory rows instead.
 */
@IsTest
private class OrgXRayControllerTest {

    private static Map<String, Object> parse(String json) {
        return (Map<String, Object>) System.JSON.deserializeUntyped(json);
    }

    private static List<SObject> rows(String json) {
        return (List<SObject>) System.JSON.deserialize(json, List<SObject>.class);
    }

    @IsTest
    static void licensesReturnsCounts() {
        Map<String, Object> r = parse(OrgXRayController.checkLicenses(90));
        Assert.areEqual('licenses', r.get('key'));
        Assert.isNotNull(r.get('ok'));
        if ((Boolean) r.get('ok')) {
            Map<String, Object> data = (Map<String, Object>) r.get('data');
            Assert.isTrue((Integer) data.get('activeUsers') >= 1, 'The running user is active');
        }
    }

    @IsTest
    static void licensesDefaultsDays() {
        Map<String, Object> r = parse(OrgXRayController.checkLicenses(null));
        if ((Boolean) r.get('ok')) {
            Map<String, Object> data = (Map<String, Object>) r.get('data');
            Assert.areEqual(90, data.get('days'));
            Assert.isNotNull(data.get('isSandbox'));
            Assert.isNotNull(data.get('byLicense'));
        }
    }

    @IsTest
    static void userRowNamesProfileAndLicense() {
        Id licenseId = '100000000000001';
        SObject u = rows('[{"attributes":{"type":"User"},"Id":"005000000000001","Username":"ana@example.com",'
            + '"Profile":{"attributes":{"type":"Profile"},"Name":"Sales","UserLicenseId":"' + licenseId + '"}}]')[0];

        Map<String, Object> row = OrgXRayController.userRow(u, new Map<Id, String>{ licenseId => 'Salesforce' });

        Assert.areEqual('ana@example.com', row.get('username'));
        Assert.areEqual('Sales', row.get('profile'));
        Assert.areEqual('Salesforce', row.get('license'));
    }

    @IsTest
    static void automationRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkAutomation());
        Assert.areEqual('automation', r.get('key'));
        Assert.isNotNull(r.get('ok'));
    }

    @IsTest
    static void tallyFlowsSkipsManagedAndFindsProcessBuilders() {
        List<SObject> flows = rows('['
            + '{"attributes":{"type":"FlowDefinitionView"},"ApiName":"Old","Label":"Old","ProcessType":"Workflow"},'
            + '{"attributes":{"type":"FlowDefinitionView"},"ApiName":"New","Label":"New","ProcessType":"Flow"},'
            + '{"attributes":{"type":"FlowDefinitionView"},"ApiName":"Pkg","Label":"Pkg","ProcessType":"Workflow",'
            + '"NamespacePrefix":"acme"}]');
        Map<String, Integer> byType = new Map<String, Integer>();
        List<Map<String, Object>> legacy = new List<Map<String, Object>>();

        OrgXRayController.tallyFlows(flows, true, byType, legacy);

        Assert.areEqual(1, legacy.size());
        Assert.areEqual('Old', legacy[0].get('apiName'));
        Assert.areEqual(1, byType.get('Workflow'));
        Assert.areEqual(1, byType.get('Flow'));
    }

    @IsTest
    static void triggersAreGroupedByObject() {
        List<SObject> triggers = rows('['
            + '{"attributes":{"type":"ApexTrigger"},"Name":"One","TableEnumOrId":"Account","ApiVersion":40.0},'
            + '{"attributes":{"type":"ApexTrigger"},"Name":"Two","TableEnumOrId":"Account","ApiVersion":62.0},'
            + '{"attributes":{"type":"ApexTrigger"},"Name":"Three","TableEnumOrId":"Contact","ApiVersion":62.0}]');
        Map<String, List<String>> byObject = new Map<String, List<String>>();

        Integer oldTriggers = OrgXRayController.collectTriggers(triggers, byObject);
        List<Map<String, Object>> multi = OrgXRayController.multiTriggerRows(byObject);

        Assert.areEqual(1, oldTriggers);
        Assert.areEqual(1, multi.size(), 'Only Account has more than one trigger');
        Assert.areEqual(2, ((List<String>) multi[0].get('triggers')).size());
    }

    @IsTest
    static void accessRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkAccess());
        Assert.areEqual('access', r.get('key'));
        Assert.isNotNull(r.get('ok'));
    }

    @IsTest
    static void modifyAllCombinesProfileAndPermissionSet() {
        String assignee = '"AssigneeId":"005000000000001","Assignee":{"attributes":{"type":"User"},'
            + '"Name":"Ana","Username":"ana@example.com"}';
        List<SObject> assignments = rows('['
            + '{"attributes":{"type":"PermissionSetAssignment"},' + assignee + ','
            + '"PermissionSet":{"attributes":{"type":"PermissionSet"},"IsOwnedByProfile":true,'
            + '"Profile":{"attributes":{"type":"Profile"},"Name":"System Administrator"}}},'
            + '{"attributes":{"type":"PermissionSetAssignment"},' + assignee + ','
            + '"PermissionSet":{"attributes":{"type":"PermissionSet"},"IsOwnedByProfile":false,"Label":"Data Admin"}}]');
        Map<Id, Map<String, Object>> modifyAll = new Map<Id, Map<String, Object>>();

        for (SObject psa : assignments) {
            OrgXRayController.addModifyAll(psa, modifyAll);
        }

        Assert.areEqual(1, modifyAll.size(), 'One person, two sources of access');
        List<String> via = (List<String>) modifyAll.values()[0].get('via');
        Assert.areEqual('Profile: System Administrator', via[0]);
        Assert.areEqual('Permission set: Data Admin', via[1]);
    }

    @IsTest
    static void duplicatesRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkDuplicates());
        Assert.areEqual('duplicates', r.get('key'));
        if ((Boolean) r.get('ok')) {
            Map<String, Object> data = (Map<String, Object>) r.get('data');
            Map<String, Object> rules = (Map<String, Object>) data.get('activeRules');
            Assert.isTrue(rules.containsKey('Lead'));
        }
    }

    @IsTest
    static void fieldsScansAccounts() {
        Map<String, Object> r = parse(OrgXRayController.checkFields('Account', 100, 90));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
        Map<String, Object> data = (Map<String, Object>) r.get('data');
        Assert.areEqual('Account', data.get('object'));
        Assert.areEqual(90, data.get('minAgeDays'));
    }

    @IsTest
    static void changedSinceFindsRecentlyChangedFields() {
        List<SObject> definitions = rows('['
            + '{"attributes":{"type":"FieldDefinition"},"QualifiedApiName":"New_Field__c",'
            + '"LastModifiedDate":"2026-06-01T00:00:00.000+0000"},'
            + '{"attributes":{"type":"FieldDefinition"},"QualifiedApiName":"Old_Field__c",'
            + '"LastModifiedDate":"2020-06-01T00:00:00.000+0000"}]');

        Set<String> recent = OrgXRayController.changedSince(definitions, Datetime.newInstanceGmt(2026, 1, 1));

        Assert.isTrue(recent.contains('new_field__c'));
        Assert.isFalse(recent.contains('old_field__c'));
    }

    @IsTest
    static void fieldsHandlesUnknownObject() {
        Map<String, Object> r = parse(OrgXRayController.checkFields('Not_A_Real_Object__c', 100, 90));
        Assert.isFalse((Boolean) r.get('ok'));
        Assert.isNotNull(r.get('error'));
    }

    @IsTest
    static void tallyRowCountsFilledValuesAndTickedCheckboxes() {
        Lead row = new Lead(LastName = 'XRay', Company = '', DoNotCall = true, HasOptedOutOfEmail = false);
        List<String> chunk = new List<String>{ 'LastName', 'Company', 'Website', 'DoNotCall', 'HasOptedOutOfEmail' };
        Set<String> booleans = new Set<String>{ 'DoNotCall', 'HasOptedOutOfEmail' };
        Map<String, Integer> filled = new Map<String, Integer>();
        for (String f : chunk) {
            filled.put(f, 0);
        }

        OrgXRayController.tallyRow(row, chunk, booleans, filled);

        Assert.areEqual(1, filled.get('LastName'));
        Assert.areEqual(0, filled.get('Company'), 'An empty string is not filled');
        Assert.areEqual(0, filled.get('Website'));
        Assert.areEqual(1, filled.get('DoNotCall'));
        Assert.areEqual(0, filled.get('HasOptedOutOfEmail'), 'An unticked checkbox is not filled');
    }

    @IsTest
    static void summarizeFieldsListsRarelyUsedLowestFirst() {
        OrgXRayController.CheckResult r = new OrgXRayController.CheckResult('fields:Test');
        List<String> fields = new List<String>{ 'Busy__c', 'Rare__c', 'Empty__c' };
        Map<String, String> labels = new Map<String, String>{
            'Busy__c' => 'Busy', 'Rare__c' => 'Rare', 'Empty__c' => 'Empty'
        };
        Map<String, Integer> filled = new Map<String, Integer>{ 'Busy__c' => 50, 'Rare__c' => 1, 'Empty__c' => 0 };

        OrgXRayController.summarizeFields(r, fields, labels, new Set<String>{ 'Rare__c' }, filled, 100);

        Assert.areEqual(3, r.data.get('scannedFieldCount'));
        Assert.areEqual(2, r.data.get('rarelyUsedCount'));
        Assert.areEqual(1, r.data.get('neverUsedCount'));
        List<OrgXRayController.FieldStat> rare = (List<OrgXRayController.FieldStat>) r.data.get('rarelyUsed');
        Assert.areEqual('Empty__c', rare[0].apiName);
        Assert.areEqual('Rare__c', rare[1].apiName);
        Assert.isTrue(rare[1].isCheckbox);
    }

    @IsTest
    static void summarizeFieldsHandlesNoRecords() {
        OrgXRayController.CheckResult r = new OrgXRayController.CheckResult('fields:Test');

        OrgXRayController.summarizeFields(r, new List<String>{ 'Any__c' }, new Map<String, String>(),
            new Set<String>(), new Map<String, Integer>{ 'Any__c' => 0 }, 0);

        Assert.areEqual(0, r.data.get('rarelyUsedCount'));
    }

    @IsTest
    static void leadFlowRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkLeadFlow());
        Assert.areEqual('leadFlow', r.get('key'));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
    }

    @IsTest
    static void sourceRowClassifiesAndAverages() {
        Datetime now = Datetime.now();

        Map<String, Object> quiet = OrgXRayController.sourceRow('Web', 60, 0, now.addHours(-120), now.getTime());
        Assert.areEqual('quiet', quiet.get('status'));
        Assert.areEqual(1.0, quiet.get('perDay'));
        Assert.areEqual(120.0, quiet.get('hoursSinceLast'));

        Map<String, Object> noDate = OrgXRayController.sourceRow('Web', 3, 0, null, now.getTime());
        Assert.areEqual('ok', noDate.get('status'));
        Assert.isNull(noDate.get('hoursSinceLast'));
    }

    @IsTest
    static void limitsRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkLimits());
        Assert.areEqual('limits', r.get('key'));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
    }

    @IsTest
    static void limitRowWorksOutPercentage() {
        Assert.areEqual(25.0, OrgXRayController.limitRow('DataStorageMB', 50, 200).get('pct'));
        Assert.areEqual(0, OrgXRayController.limitRow('DataStorageMB', 50, 0).get('pct'));
    }

    @IsTest
    static void jobsRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkJobs());
        Assert.areEqual('jobs', r.get('key'));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
    }

    @IsTest
    static void staleDataRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkStaleData());
        Assert.areEqual('staleData', r.get('key'));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
    }

    @IsTest
    static void safeCountReturnsNullWhenQueryFails() {
        Assert.isNull(OrgXRayController.safeCount('SELECT COUNT() FROM Not_A_Real_Object__c'));
    }

    @IsTest
    static void countOldFlowsSkipsManagedAndNewFlows() {
        List<SObject> flows = rows('['
            + '{"attributes":{"type":"FlowDefinitionView"},"ApiName":"Old","ApiVersion":40.0},'
            + '{"attributes":{"type":"FlowDefinitionView"},"ApiName":"New","ApiVersion":62.0},'
            + '{"attributes":{"type":"FlowDefinitionView"},"ApiName":"Pkg","ApiVersion":30.0,"NamespacePrefix":"acme"}]');

        Assert.areEqual(1, OrgXRayController.countOldFlows(flows, true));
    }

    @IsTest
    static void securityRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkSecurity());
        Assert.areEqual('security', r.get('key'));
        Assert.isNotNull(r.get('ok'));
    }

    @IsTest
    static void countFailedLoginsIgnoresSuccess() {
        List<SObject> logins = rows('['
            + '{"attributes":{"type":"LoginHistory"},"Status":"Success"},'
            + '{"attributes":{"type":"LoginHistory"},"Status":"Invalid Password"},'
            + '{"attributes":{"type":"LoginHistory"},"Status":"Failed: Computer activation required"}]');

        Assert.areEqual(2, OrgXRayController.countFailedLogins(logins));
    }

    @IsTest
    static void dataQualityRuns() {
        Map<String, Object> r = parse(OrgXRayController.checkDataQuality());
        Assert.areEqual('dataQuality', r.get('key'));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
    }

    @IsTest
    static void listCustomObjectsRuns() {
        Map<String, Object> r = parse(OrgXRayController.listCustomObjects(5));
        Assert.areEqual('customObjects', r.get('key'));
        Assert.isTrue((Boolean) r.get('ok'), 'Check failed: ' + r.get('error'));
    }

    @IsTest
    static void largestObjectsKeepsTheFullestAndDropsSmallOnes() {
        List<String> names = OrgXRayController.largestObjects(new Map<String, Integer>{
            'Small__c' => 5, 'Big__c' => 900, 'Bigger__c' => 5000, 'Mid__c' => 300
        }, 2);

        Assert.areEqual(new List<String>{ 'Bigger__c', 'Big__c' }, names);
    }

    @IsTest
    static void classifySourceRules() {
        // 60 leads in 60 days, none for 5 days: quiet
        Assert.areEqual('quiet', OrgXRayController.classifySource(60, 0, 120));
        // 60 leads in 60 days, last one 10 hours ago: ok
        Assert.areEqual('ok', OrgXRayController.classifySource(60, 7, 10));
        // 120 leads in 60 days but only 2 in the last week: dropping
        Assert.areEqual('dropping', OrgXRayController.classifySource(120, 2, 20));
        // Small source, a lead every few weeks: never flagged
        Assert.areEqual('ok', OrgXRayController.classifySource(3, 0, 400));
        Assert.areEqual('ok', OrgXRayController.classifySource(null, null, null));
    }
}
