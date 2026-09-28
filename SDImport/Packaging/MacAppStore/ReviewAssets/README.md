# Version 1.1 trial review screenshot

- `1.1-trial-purchase-local.png` is the unmodified 1920 x 1200 capture of the
  locally built SD Card Import trial purchase sheet. It was captured on
  September 28, 2026 from the app window only, with no personal media shown.
- `1.1-trial-purchase-review.png` is the 2560 x 1600 RGB image uploaded to the
  14-day Trial IAP's App Review Information in App Store Connect. It is a
  deterministic resize of the native capture, flattened on white because Mac
  review screenshots require a supported size and no alpha channel.

The captured Debug app was version 1.1 (12), built from commit
`3968f1473900bbcb4b66a1f140625b021b7265aa`. It was launched locally, so
this is not a TestFlight or App Store build capture. Version 1.1 (14), built
from the same commit, and the 14-day Trial IAP were submitted together on
September 28, 2026. [Submission details](https://appstoreconnect.apple.com/apps/6807178069/distribution/reviewsubmissions/details/bf2e30b7-3509-4e89-938b-140111d17e01)
showed both items Waiting for Review. The existing signed StoreKit integration
suite passed all seven tests before submission.

The sheet's Family Sharing line refers to the lifetime purchase. Family
Sharing is off for the trial IAP, as clarified in the review notes.
