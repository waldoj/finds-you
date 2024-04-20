import requests

def fetch_books_with_snippets(query, api_key):
    url = "https://www.googleapis.com/books/v1/volumes"
    start_index = 0
    snippets = []

    while True:
        params = {
            'q': query,
            'startIndex': start_index,
            'maxResults': 40,  # You can adjust this number, up to 40 is allowed
            'key': api_key
        }
        response = requests.get(url, params=params)
        data = response.json()

        if 'items' not in data:
            break  # Exit loop if no more items are found

        for item in data['items']:
            if 'searchInfo' in item and 'textSnippet' in item['searchInfo']:
                snippets.append(item['searchInfo']['textSnippet'])

        # Check if we need to continue paging
        if 'totalItems' in data and data['totalItems'] > start_index + 40:
            start_index += 40
        else:
            break  # Exit loop if we have fetched all items

    return snippets

def save_snippets_to_file(snippets, file_name):
    with open(file_name, 'a', encoding='utf-8') as file:
        for snippet in snippets:
            if "finds you" in snippet:
                file.write(snippet + '\n')  # Write each snippet in a new paragraph

# Usage example
api_key = 'API_KEY'  # Replace with your actual Google API key
query = '"finds you and"'  # Replace with your search query
snippets = fetch_books_with_snippets(query, api_key)
save_snippets_to_file(snippets, 'finds_you.txt')
print("Snippets successfully saved to file.")
