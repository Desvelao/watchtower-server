# Fix problem with `xml` dependency

git clone https://github.com/lubyk/xml xml_lua
cd xml_lua/
git checkout REL-1.1.3
cp xml-1.1.3-1.rockspec xml-1.1.3-1.rockspec.bk
rm xml-1.1.3-1.rockspec
vim xml-1.1.3-1.rockspec
luarocks-5.1 install xml-1.1.3-1.rockspec
luarocks-5.1 install lua-requests

# Install dependencies of WebScraper

luarocks-5.1 install htmlparser
apk add zlib-dev
luarocks-5.1 install lua-zlib
luarocks-5.1 install dkjson
