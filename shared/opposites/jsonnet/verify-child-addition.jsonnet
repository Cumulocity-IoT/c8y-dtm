// Structural check of the c8y_LinkedSeriesReverseIndex child addition of one device.
// Used as --outputTemplate of: c8y inventory children list --childType addition
// input.value is { id: <source device id> }, output is the raw children list response.
// Emits either an error record or { id, childAdditionId, type, linkedAssets }; the per
// link matching happens afterwards in shared/jq/verify-match-links.jq.
// Every field access is guarded so that one malformed managed object cannot make the
// template fail, which would silently drop the record for that device.
local hasValue(obj, field) = std.isObject(obj) && std.objectHas(obj, field) && obj[field] != null && std.toString(obj[field]) != "";
local get(obj, field) = if std.isObject(obj) && std.objectHas(obj, field) then obj[field] else null;
local str(v) = if v == null then "" else std.toString(v);
local refsFromOutput(obj) =
    if std.isObject(obj) && std.objectHas(obj, "references") && std.isArray(obj.references) then
        obj.references
    else if std.isObject(obj) && std.objectHas(obj, "managedObjects") && std.isArray(obj.managedObjects) then
        std.map(function(mo) { managedObject: mo }, obj.managedObjects)
    else
        null;
local deviceId = str(get(input.value, "id"));
local references = refsFromOutput(output);
if hasValue(output, "errorType") then
    { id: deviceId, "error": "CumulocityError", c8yError: output }
else if references == null then
    { id: deviceId, "error": "NoReferencesFieldError", rawOutput: output }
else if std.length(references) == 0 then
    { id: deviceId, "error": "NoChildAdditionsError" }
else if std.length(references) > 1 then
    { id: deviceId, "error": "TooManyChildAdditionsError",
      childAdditionIds: std.map(function(r) str(get(get(r, "managedObject"), "id")), references) }
else
    local managedObject = get(references[0], "managedObject");
    if !std.isObject(managedObject) then
        { id: deviceId, "error": "ManagedObjectNotObjectError" }
    else
        local common = { id: deviceId, childAdditionId: str(get(managedObject, "id")), type: str(get(managedObject, "type")) };
        if !hasValue(managedObject, "c8y_LinkedAssets") then
            common + { "error": "MissingLinkedAssetsInChildAdditionError" }
        else if !std.isArray(managedObject.c8y_LinkedAssets) || std.length(managedObject.c8y_LinkedAssets) == 0 then
            common + { "error": "LinkedAssetsNotArrayOrEmptyError" }
        else
            common + { linkedAssets: managedObject.c8y_LinkedAssets }
