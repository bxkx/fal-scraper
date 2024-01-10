# frozen_string_literal: true

require "async"
require "net/http"
require "json"
require "rubyXL"
require "rubyXL/convenience_methods/workbook"
require "open-uri"
require "nokogiri"
require "active_support/all"
require "chronic"

CLIENT_ID = ""
SEASON_START = Time.new(2023, 12, 31, 22, 0, 0, "UTC")

LAST_DISC_WEEK = [SEASON_START, SEASON_START + 2.weeks, SEASON_START + 4.weeks, SEASON_START + 6.weeks,
                  SEASON_START + 8.weeks, SEASON_START + 10.weeks, SEASON_START + 12.weeks, SEASON_START + 13.weeks]
                 .each_cons(2)
                 .select { |e| Time.now.utc.between?(e.first, e.last) }.flatten.shift

IDS = [50_392, 55_690, 50_803, 52_701, 53_889, 55_866, 53_488, 53_421, 53_730, 52_816, 54_829, 54_265, 51_673, 49_613,
       54_794, 54_869,
       53_223, 54_632, 54_837, 55_129, 53_590, 54_449, 52_359, 54_617, 51_648, 54_722, 56_352, 55_358, 55_774, 55_998,
       56_242, 55_397, 55_973, 52_482].freeze

abort("!!! You need to add your API client ID !!!") if CLIENT_ID.empty?

Time.zone = "Pacific Time (US & Canada)"
Chronic.time_class = Time.zone

def get_response(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req["X-MAL-CLIENT-ID"] = CLIENT_ID

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
  JSON.parse(res.body)
end

def scrape_threads(id)
  url = "https://myanimelist.net/forum/?animeid=#{id}}&topic=episode"
  uri = URI.parse(url)

  res = Net::HTTP.get_response(uri)
  Nokogiri::HTML(res.body)
end

def get_data(id)
  url = "https://api.myanimelist.net/v2/anime/#{id}?fields=title,mean,num_favorites,statistics"
  get_response(url)
end

def get_topic_content(topic_id)
  url = "https://api.myanimelist.net/v2/forum/topic/#{topic_id}?limit=100"
  topic_content = [] << response = get_response(url)

  (1..).each do |i|
    url = "https://api.myanimelist.net/v2/forum/topic/#{topic_id}?offset=#{100 * i}&limit=100"
    response["paging"].key?("next") ? (topic_content << response = get_response(url)) : (return topic_content)
  end
end

def get_unique_users(contents)
  unique_users = []
  contents.map do |content|
    content["data"]["posts"].filter_map do |post|
      unique_users << post["created_by"]["name"] if Time.parse(post["created_at"]).after?(LAST_DISC_WEEK)
    end
  end
end

def get_users(anime)
  Async do
    topic_contents = anime.map { |topic| Async { get_topic_content(topic[0]) } }.map(&:wait)

    user_names = topic_contents.map { |topic| Async { get_unique_users(topic).flatten } }.map(&:wait)

    anime.map.with_index { |topic, idx| Async { user_names[idx] << topic[1] } }.map(&:wait)
  end
end

def get_ids_and_lp(html)
  topic_id = []
  last_poster = []
  dates = []

  (1..).each do |i|
    break if (topic_row = html.at_css("tr#topicRow#{i}")).nil?

    topic_id << topic_row["data-topic-id"]
    last_poster << html.css("tr#topicRow#{i} td.forum_boardrow1").text.strip.match(/by\s+(.+)/i).to_s.split[1]
    date_element = html.at_xpath("//tr[@id='topicRow#{i}']//td[@class='forum_boardrow1' and @align='right']/br/following-sibling::text()").text.strip

    dates << Time.parse(Chronic.parse(date_element).to_s).utc
  end
  topic_id.zip(last_poster, dates).select { |e| e[2].after?(LAST_DISC_WEEK) }
end

# rubocop:disable Metrics/MethodLength
def anime_data
  anime_data = []
  Async do
    anime_data = IDS.map { |id| Async { get_data(id) } }.map(&:wait)
    users = IDS.map { |id| Async { get_ids_and_lp(scrape_threads(id)) } }.map(&:wait)
    users.map! { |id| Async { get_users(id).wait } }.map!(&:wait)

    users.map.with_index do |arr, idx|
      Async do
        anime_data[idx]["unique_posters"] = arr.map do |names|
          Async { names.flatten.uniq.length }
        end.map.sum(&:wait)
      end
    end.map(&:wait)
  end
  anime_data
end
# rubocop:enable Metrics/MethodLength

headers = %w[Date Title Score Watching Dropped Favorites Planning UniqP]

workbook = RubyXL::Workbook.new
sheet = workbook.first

timestamp = Time.new

headers.each_with_index do |e, idx|
  sheet.add_cell(0, idx, e)
end

anime_data.each.with_index(1) do |e, idx|
  sheet.add_cell(idx, 0, timestamp.strftime("%Y-%m-%d"))
  sheet.add_cell(idx, 1, e["title"])
  sheet.add_cell(idx, 2, e["mean"])
  sheet.add_cell(idx, 3, e["statistics"]["status"]["watching"].to_i)
  sheet.add_cell(idx, 4, e["statistics"]["status"]["dropped"].to_i)
  sheet.add_cell(idx, 5, e["num_favorites"])
  sheet.add_cell(idx, 6, e["statistics"]["status"]["plan_to_watch"].to_i)
  sheet.add_cell(idx, 7, e["unique_posters"])
end

workbook.write("FAL #{timestamp.strftime("%Y-%m-%d %H:%M:%S")}.xlsx")
