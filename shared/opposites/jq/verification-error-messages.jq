# Turns verification verdicts into one console message per problem.
# Input:  the failing verdicts of verify-match-links.jq, slurped (jq -s)
# Output: text lines of "<ErrorType>\t<message>" (use jq -r). MissingLinkedSeries
#         verdicts produce one line per missing link, everything else one per device.
# The measurement gap those missing links caused is a separate question, answered by the
# opposites-gap command against this file.
sort_by(.id) | .[] | . as $r |
        if .error == "CumulocityError" then
            "CumulocityError\t" + ((.c8yError.message // "request failed") | tostring)
              + " (device " + (.id|tostring) + ", affects " + (.linkCount|tostring) + " links of "
              + ((.affectedAssets|length)|tostring) + " assets: " + ((.affectedAssets // [])[0:5] | join(", ")) + ")"
        elif .error == "MissingLinkedSeriesInChildAdditionError" then
            (.missingLinks[] |
                "MissingLinkedSeriesInChildAdditionError\tasset " + (.assetId|tostring)
                  + " series " + (.fragment|tostring) + "." + (.series|tostring)
                  + " is missing in child addition " + ($r.childAdditionId|tostring)
                  + " of device " + ($r.id|tostring)
                  + " (source " + (.sourceFragment|tostring) + "." + (.sourceSeries|tostring)
                  + ", source series present: " + (.sourceSeriesPresent|tostring) + ")")
        elif .error == "NoVerificationResultError" then
            "NoVerificationResultError\tdevice " + (.id|tostring) + " returned no verification record, "
              + (.linkCount|tostring) + " links could not be verified"
        elif .error == "NoChildAdditionsError" then
            "NoChildAdditionsError\tdevice " + (.id|tostring) + " has no c8y_LinkedSeriesReverseIndex child addition, "
              + (.linkCount|tostring) + " links affected"
        elif .error == "TooManyChildAdditionsError" then
            "TooManyChildAdditionsError\tdevice " + (.id|tostring) + " has more than one child addition ("
              + ((.childAdditionIds // []) | join(", ")) + "), " + (.linkCount|tostring) + " links affected"
        elif .error == "NoReferencesFieldError" then
            "NoReferencesFieldError\tdevice " + (.id|tostring) + " response had no references field, "
              + (.linkCount|tostring) + " links affected"
        elif .error == "ManagedObjectNotObjectError" then
            "ManagedObjectNotObjectError\tdevice " + (.id|tostring) + " managedObject is not an object, "
              + (.linkCount|tostring) + " links affected"
        elif .error == "MissingLinkedAssetsInChildAdditionError" then
            "MissingLinkedAssetsInChildAdditionError\tdevice " + (.id|tostring) + " child addition "
              + (.childAdditionId|tostring) + " has no c8y_LinkedAssets fragment, " + (.linkCount|tostring) + " links affected"
        elif .error == "LinkedAssetsNotArrayOrEmptyError" then
            "LinkedAssetsNotArrayOrEmptyError\tdevice " + (.id|tostring) + " child addition "
              + (.childAdditionId|tostring) + " c8y_LinkedAssets is not an array or is empty, " + (.linkCount|tostring) + " links affected"
        else
            (.error|tostring) + "\tdevice " + (.id|tostring) + ", " + (.linkCount|tostring) + " links affected"
        end
