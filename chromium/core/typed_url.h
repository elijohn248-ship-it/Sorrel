// Typed text -> destination, per spec/address-and-search.md (fixtures
// `resolver` and `bangs`): bang, then address, then search.
//
// Owner: wave-3 agent 6 (cx-commandbar).
#ifndef BIRCH_CORE_TYPED_URL_H_
#define BIRCH_CORE_TYPED_URL_H_

#include <optional>
#include <string>

#include "core/bangs.h"

namespace birch::core {

// An address the text names, or nullopt when it should be searched.
std::optional<std::string> UrlFromTyped(const std::string& text);
// The search engine template (%s = query) filled with |query|.
std::string SearchUrl(const std::string& template_url, const std::string& query);
// Bang (when |bangs| is given), then address, then search.
std::string Destination(const std::string& text,
                        const std::string& search_template,
                        const Bangs* bangs = nullptr);

}  // namespace birch::core

#endif  // BIRCH_CORE_TYPED_URL_H_
