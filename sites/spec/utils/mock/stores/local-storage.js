import LocalStorage from "src/stores/local-storage";

export default class MockLocalStorage extends LocalStorage {
  constructor() {
    this.map = {};
  }
  load( key ) {
    return this.map[key];
  }
  save( key, data ) {
    this.map[key] = data;
  }
}