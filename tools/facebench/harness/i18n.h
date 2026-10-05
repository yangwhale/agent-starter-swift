// facebench stub: strings only feed text that the bench does not render.
#pragma once
enum StrId { S_SEND, S_APPROVE, S_HOLD_REJECT, S_SKIN, S_LIGHT, S_CLAIM_Q,
             S_CLAIM_DONE, S_CLAIM_OK, S_YOU };
inline const char* tr(StrId) { return ""; }
inline bool langEn() { return false; }
