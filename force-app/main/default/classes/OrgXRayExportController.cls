/**
 * Org X-Ray by Virago
 * Builds the CSV downloads, so people can work through the lists in a spreadsheet.
 * Runs the same read-only checks as the dashboard. Nothing is stored.
 */
public with sharing class OrgXRayExportController {

    // All objects share one transaction here, so wide orgs stop before the CPU limit
    private static final Integer CPU_BUDGET_MS = 6000;
    // Tells Excel the file is UTF-8, so names like Kočić stay readable
    private static final String BYTE_ORDER_MARK = '﻿';

    public String csv { get; private set; }
    public String fileName { get; private set; }

    public OrgXRayExportController() {
        Map<String, String> params = ApexPages.currentPage().getParameters();
        if (params.get('type') == 'fields') {
            fileName = 'org-x-ray-unused-fields.csv';
            csv = fieldsCsv(params.get('objects'), toInteger(params.get('sample')), toInteger(params.get('minAge')));
        } else {
            fileName = 'org-x-ray-unused-licenses.csv';
            csv = usersCsv(OrgXRayController.checkLicenses(null));
        }
    }

    private static Integer toInteger(String value) {
        return value != null && value.isNumeric() ? Integer.valueOf(value) : null;
    }

    @TestVisible
    private static String usersCsv(String raw) {
        List<String> lines = new List<String>{ line(new List<Object>{ 'Name', 'Username', 'Profile', 'License', 'Last login' }) };
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(raw);
        if (r.get('ok') == true) {
            Map<String, Object> data = (Map<String, Object>) r.get('data');
            for (Object o : (List<Object>) data.get('users')) {
                Map<String, Object> u = (Map<String, Object>) o;
                Object lastLogin = u.get('lastLogin');
                lines.add(line(new List<Object>{
                    u.get('name'), u.get('username'), u.get('profile'), u.get('license'),
                    lastLogin == null ? 'Never' : String.valueOf(lastLogin).left(10)
                }));
            }
        }
        return BYTE_ORDER_MARK + String.join(lines, '\n');
    }

    private static String fieldsCsv(String objects, Integer sample, Integer minAge) {
        List<String> lines = new List<String>{ line(new List<Object>{ 'Object', 'Field', 'API name', 'Filled %' }) };
        for (String obj : (String.isBlank(objects) ? new List<String>() : objects.split(','))) {
            if (Limits.getCpuTime() > CPU_BUDGET_MS) {
                break;
            }
            lines.addAll(fieldLines(obj, OrgXRayController.checkFields(obj, sample, minAge)));
        }
        return BYTE_ORDER_MARK + String.join(lines, '\n');
    }

    @TestVisible
    private static List<String> fieldLines(String obj, String raw) {
        List<String> lines = new List<String>();
        Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(raw);
        Map<String, Object> data = (Map<String, Object>) r.get('data');
        if (r.get('ok') != true || data.get('rarelyUsed') == null) {
            return lines;
        }
        for (Object o : (List<Object>) data.get('rarelyUsed')) {
            Map<String, Object> f = (Map<String, Object>) o;
            lines.add(line(new List<Object>{ obj, f.get('label'), f.get('apiName'), f.get('filledPct') }));
        }
        return lines;
    }

    private static String line(List<Object> cells) {
        List<String> escaped = new List<String>();
        for (Object cell : cells) {
            escaped.add(cell(cell));
        }
        return String.join(escaped, ',');
    }

    /** Quotes every value, and stops a spreadsheet from running a value that looks like a formula. */
    @TestVisible
    private static String cell(Object value) {
        String text = value == null ? '' : String.valueOf(value);
        if (text.length() > 0 && '=+-@'.contains(text.left(1))) {
            text = '\'' + text;
        }
        return '"' + text.replace('"', '""') + '"';
    }
}
