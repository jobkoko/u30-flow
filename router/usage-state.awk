# Persistent daily delta from the subscription provider's cumulative byte count.
# TSV: day first last provider-used observed partial reset fingerprint total expire
BEGIN { FS=OFS="\t" }
NR==1 { oldday=$1; first=$2; last=$3; prev=$4; observed=$5; partial=$6; reset=$7; oldfinger=$8 }
END {
    if (!oldday || oldfinger != fingerprint) {
        first=now; observed=0; partial=1; reset=0
    } else if (oldday != day) {
        # A boundary sample within two minutes, preceded by a recent sample,
        # permits a new complete observation day. Other gaps remain explicit.
        partial=!(now-midnight <= 120 && last >= midnight-600 && last <= midnight)
        first=now; observed=0; reset=0
    } else if (used >= prev) {
        observed += used-prev
    } else {
        # A provider reset cannot be reconstructed exactly between samples.
        observed += used; reset=1; partial=1
    }
    printf "%s\t%.0f\t%.0f\t%.0f\t%.0f\t%d\t%d\t%s\t%.0f\t%.0f\n", day,first,now,used,observed,partial,reset,fingerprint,total,expire
}
