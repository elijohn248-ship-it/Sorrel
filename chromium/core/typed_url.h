// Wave-2 stand-in for typed text -> URL, so the shell's address field works.
// It follows spec/address-and-search.md ▸ "Typed text → destination" for
// addresses and plain searches but has NO bangs and is not checked against
// spec/fixtures/resolver.json. Wave-3 agent 6 (cx-commandbar) owns this file
// and replaces it with the full resolver (bangs included) that passes the
// resolver and bangs fixtures.
#ifndef BIRCH_CORE_TYPED_URL_H_
#define BIRCH_CORE_TYPED_URL_H_

#include <optional>
#include <string>

namespace birch::core {

// An address the text names, or nullopt when it should be searched.
std::optional<std::string> UrlFromTyped(const std::string& text);
// The search engine template (%s = query) filled with |query|.
std::string SearchUrl(const std::string& template_url, const std::string& query);
// Address, else search.
std::string Destination(const std::string& text,
                        const std::string& search_template);

}  // namespace birch::core

#endif  // BIRCH_CORE_TYPED_URL_H_
