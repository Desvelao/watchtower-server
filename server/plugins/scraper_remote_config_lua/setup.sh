# Fix problem with `xml` dependency
current_dir=$(pwd)

if ! luarocks-5.1 show xml > /dev/null 2>&1; then
  echo "xml not installed, installing..."
  tmp_dir=/tmp/xml
  rm -rf $tmp_dir
  mkdir -p $tmp_dir
  cd $tmp_dir
  apk add git zlib-dev
  git clone https://github.com/lubyk/xml xml_lua
  cd xml_lua/
  git checkout REL-1.1.3
  echo $script_dir
  cp xml-1.1.3-1.rockspec xml-1.1.3-1.rockspec.bk
  cp $current_dir/xml.rockspec $tmp_dir/xml_lua/xml-1.1.3-1.rockspec
  luarocks-5.1 install $tmp_dir/xml_lua/xml-1.1.3-1.rockspec
  rm -rf $tmp_dir
  echo "xml installed!"
fi

if ! luarocks-5.1 show webscraper > /dev/null 2>&1; then
  cd $current_dir
  echo "webscraper not installed, installing..." \
  && luarocks-5.1 install webscraper \
  && echo "webscraper installed!"
fi
