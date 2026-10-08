#include "difz.h"
#include <string.h>

int main(void) {
	const unsigned char a[] = "abcdef";
	const unsigned char b[] = "abcXYZ";
	unsigned char *patch = NULL;
	size_t patch_len = 0;
	if (difz_diff(a, sizeof a, b, sizeof b, &patch, &patch_len) != 0) {
		return 1;
	}
	unsigned char *out = NULL;
	size_t out_len = 0;
	const int rc = difz_patch(a, sizeof a, patch, patch_len, &out, &out_len);
	const int ok = rc == 0 && out_len == sizeof b && memcmp(out, b, sizeof b) == 0;
	if (rc == 0) difz_free(out, out_len);
	difz_free(patch, patch_len);
	return ok ? 0 : 1;
}
