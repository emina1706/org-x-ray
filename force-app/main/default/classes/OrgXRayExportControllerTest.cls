/**
 * No records are inserted, so a customer's triggers and validation rules cannot fail these tests.
 */
@IsTest
private class OrgXRayExportControllerTest {

    @IsTest
    static void usersDownloadIsTheDefault() {
        Test.setCurrentPage(Page.OrgXRayExport);

        OrgXRayExportController download = new OrgXRayExportController();

        Assert.areEqual('org-x-ray-unused-licenses.csv', download.fileName);
        Assert.isTrue(download.csv.contains('"Username"'));
    }

    @IsTest
    static void fieldsDownloadScansTheObjects() {
        PageReference page = Page.OrgXRayExport;
        page.getParameters().putAll(new Map<String, String>{
            'type' => 'fields', 'objects' => 'Account', 'sample' => '100', 'minAge' => '90'
        });
        Test.setCurrentPage(page);

        OrgXRayExportController download = new OrgXRayExportController();

        Assert.areEqual('org-x-ray-unused-fields.csv', download.fileName);
        Assert.isTrue(download.csv.contains('"API name"'));
    }

    @IsTest
    static void usersCsvListsEachUser() {
        String csv = OrgXRayExportController.usersCsv('{"ok":true,"data":{"users":['
            + '{"name":"Ana","username":"ana@example.com","profile":"Sales","license":"Salesforce","lastLogin":null}]}}');
        Assert.isTrue(csv.contains('"Ana","ana@example.com","Sales","Salesforce","Never"'));
    }

    @IsTest
    static void usersCsvKeepsTheHeaderWhenTheCheckFails() {
        String csv = OrgXRayExportController.usersCsv('{"ok":false,"error":"Failed","data":{}}');
        Assert.isTrue(csv.contains('"Name"'));
    }

    @IsTest
    static void fieldLinesSkipFailedAndEmptyChecks() {
        Assert.isTrue(OrgXRayExportController.fieldLines('Case', '{"ok":false,"error":"Failed","data":{}}').isEmpty());
        Assert.isTrue(OrgXRayExportController.fieldLines('Case', '{"ok":true,"data":{"skipped":true}}').isEmpty());

        List<String> lines = OrgXRayExportController.fieldLines('Account', '{"ok":true,"data":{"rarelyUsed":['
            + '{"label":"Rare","apiName":"Rare__c","filledPct":1.5}]}}');
        Assert.areEqual('"Account","Rare","Rare__c","1.5"', lines[0]);
    }

    @IsTest
    static void cellEscapesQuotesAndFormulas() {
        Assert.areEqual('"say ""hi"""', OrgXRayExportController.cell('say "hi"'));
        Assert.areEqual('"\'=SUM(A1)"', OrgXRayExportController.cell('=SUM(A1)'));
        Assert.areEqual('""', OrgXRayExportController.cell(null));
    }
}
