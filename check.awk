#!/bin/gawk -f
{ 
    line[$2][FNR!=NR] = $0
    for (i = 1; i <=NF; i++)
        fields[$2][i][FNR!=NR] = $i
}
END {
    for (i in fields) {
        for (j in fields[i]) {
            if (length(fields[i][j]) > 1 && fields[i][j][0] != fields[i][j][1]) {
                print "mine=" line[i][0]
                print "  ps=" line[i][1]
                print ""
                break
            }
        }
    }
}
